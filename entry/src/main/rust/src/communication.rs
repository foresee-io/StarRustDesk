//! Session-only chat and explicit, controller-initiated RustDesk voice calls.
//! Never log message bodies or audio. Voice frames use a bounded, stamped queue.
use super::*;
use hbb_common::message_proto::{AudioFrame, ChatMessage, VoiceCallRequest, VoiceCallResponse};
use std::collections::VecDeque;

#[derive(Default)]
struct Call {
    state: i32, // 0 idle, 1 ringing, 2 active, 3 rejected, 4 ended, 5 timeout
    timestamp: i64,
    deadline: Option<Instant>,
    queued: usize,
}
static CALL: Mutex<Call> = Mutex::new(Call { state: 0, timestamp: 0, deadline: None, queued: 0 });
static CHAT: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
const MAX_CHAT_BYTES: usize = 4096;
const MAX_CHAT_MESSAGES: usize = 100;
const MAX_VOICE_QUEUED: usize = 10;

pub(super) fn reset() {
    *CALL.lock().unwrap() = Call::default();
    CHAT.lock().unwrap().clear();
}

pub(super) fn receive_chat(text: String) {
    if text.is_empty() || text.len() > MAX_CHAT_BYTES { return; }
    let mut queue = CHAT.lock().unwrap();
    if queue.len() >= MAX_CHAT_MESSAGES { queue.pop_front(); }
    queue.push_back(text);
}

#[no_mangle]
pub extern "C" fn rust_take_chat_messages() -> *mut c_char {
    let messages: Vec<String> = CHAT.lock().unwrap().drain(..).collect();
    CString::new(serde_json::to_string(&messages).unwrap_or_else(|_| "[]".into())).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn rust_send_chat_message(text: *const c_char) -> i32 {
    let Some(text) = cstr_to_string(text) else { return -1; };
    if text.trim().is_empty() || text.len() > MAX_CHAT_BYTES { return -1; }
    let mut misc = Misc::new();
    misc.set_chat_message(ChatMessage { text, ..Default::default() });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    queue_peer_message(msg)
}

fn request(timestamp: i64, connect: bool) -> PeerMessage {
    let mut msg = PeerMessage::new();
    msg.set_voice_call_request(VoiceCallRequest {
        req_timestamp: timestamp, is_connect: connect, ..Default::default()
    });
    msg
}

#[no_mangle]
pub extern "C" fn rust_request_voice_call() -> i32 {
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) { return -2; }
    let mut call = CALL.lock().unwrap();
    if call.state == 1 || call.state == 2 { return -3; }
    let timestamp = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64)
        .max(call.timestamp + 1);
    *call = Call { state: 1, timestamp, deadline: Some(Instant::now() + Duration::from_secs(30)), queued: 0 };
    let result = queue_peer_message(request(timestamp, true));
    if result != 0 { call.state = 4; }
    emit_event("voice call requested");
    result
}

pub(super) fn receive_response(response: VoiceCallResponse) {
    let mut call = CALL.lock().unwrap();
    if call.state != 1 || call.timestamp != response.req_timestamp { return; }
    if call.deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        call.state = 5;
        let _ = queue_peer_message(request(call.timestamp, false));
        return;
    }
    call.state = if response.accepted { 2 } else { 3 };
    call.deadline = None;
    if response.accepted {
        let mut misc = Misc::new();
        misc.set_audio_format(AudioFormat { sample_rate: 48000, channels: 1, ..Default::default() });
        let mut msg = PeerMessage::new();
        msg.set_misc(misc);
        if queue_peer_message(msg) != 0 { call.state = 4; }
        emit_event("voice call accepted");
    } else { emit_event("voice call rejected"); }
}

pub(super) fn receive_request(req: VoiceCallRequest) {
    // Match the official controller flow: never start capture from an incoming request.
    if req.is_connect {
        let mut msg = PeerMessage::new();
        msg.set_voice_call_response(VoiceCallResponse {
            accepted: false, req_timestamp: req.req_timestamp, ..Default::default()
        });
        let _ = queue_peer_message(msg);
    } else {
        let mut call = CALL.lock().unwrap();
        call.state = 4;
        call.deadline = None;
        emit_event("voice call ended by peer");
    }
}

#[no_mangle]
pub extern "C" fn rust_voice_call_state() -> i32 {
    let mut call = CALL.lock().unwrap();
    if call.state == 1 && call.deadline.is_some_and(|d| Instant::now() >= d) {
        call.state = 5;
        call.deadline = None;
        let _ = queue_peer_message(request(call.timestamp, false));
        emit_event("voice call timed out");
    }
    call.state
}

#[no_mangle]
pub extern "C" fn rust_end_voice_call() -> i32 {
    let mut call = CALL.lock().unwrap();
    let active = call.state == 1 || call.state == 2;
    call.state = 4;
    call.deadline = None;
    if active {
        emit_event("voice call ended locally");
        queue_peer_message(request(call.timestamp, false))
    } else { 0 }
}

#[no_mangle]
pub extern "C" fn rust_send_voice_frame(data: *const u8, length: i32) -> i32 {
    if data.is_null() || !(1..=4000).contains(&length) { return -1; }
    let mut call = CALL.lock().unwrap();
    if call.state != 2 { return -2; }
    if call.queued >= MAX_VOICE_QUEUED { return 1; }
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    let guard = PEER_MESSAGE_SENDER.lock().unwrap();
    let Some((_, sender)) = guard.as_ref().filter(|(id, _)| *id == session_id) else { return -2; };
    let mut msg = PeerMessage::new();
    msg.set_audio_frame(AudioFrame {
        data: unsafe { std::slice::from_raw_parts(data, length as usize) }.to_vec().into(),
        ..Default::default()
    });
    if sender.send(QueuedPeerCommand::Message {
        session_id, message: msg, voice_timestamp: call.timestamp
    }).is_err() { return -2; }
    call.queued += 1;
    0
}

pub(super) fn consume_frame(timestamp: i64) -> bool {
    if timestamp == 0 { return true; }
    let mut call = CALL.lock().unwrap();
    if timestamp != call.timestamp { return false; }
    call.queued = call.queued.saturating_sub(1);
    call.state == 2
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wire_and_session_guards() {
        reset();
        for _ in 0..110 { receive_chat("hello 中文".into()); }
        assert_eq!(CHAT.lock().unwrap().len(), MAX_CHAT_MESSAGES);
        receive_chat("x".repeat(MAX_CHAT_BYTES + 1));
        assert_eq!(CHAT.lock().unwrap().len(), MAX_CHAT_MESSAGES);
        *CALL.lock().unwrap() = Call { state: 1, timestamp: 123, ..Default::default() };
        receive_response(VoiceCallResponse { accepted: true, req_timestamp: 999, ..Default::default() });
        assert_eq!(rust_voice_call_state(), 1);
        receive_response(VoiceCallResponse { accepted: false, req_timestamp: 123, ..Default::default() });
        assert_eq!(rust_voice_call_state(), 3);
        assert!(!consume_frame(123));
        let encoded = request(321, true).write_to_bytes().unwrap();
        let decoded = PeerMessage::parse_from_bytes(&encoded).unwrap();
        assert!(matches!(decoded.union, Some(message::Union::VoiceCallRequest(r)) if r.req_timestamp == 321 && r.is_connect));
        reset();
        assert!(CHAT.lock().unwrap().is_empty());
        assert_eq!(rust_voice_call_state(), 0);
    }
}
