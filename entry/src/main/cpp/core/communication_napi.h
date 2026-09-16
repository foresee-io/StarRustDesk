#pragma once
#include <napi/native_api.h>
#include "rustdesk_ffi.h"
#include "voice_capture.h"
#include <vector>

static napi_value CommunicationResult(napi_env env, int value) {
    napi_value ret;
    napi_create_int32(env, value, &ret);
    return ret;
}
static napi_value SendChatMessage(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    size_t length = 0;
    if (argc != 1 || napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok || length > 4096)
        return CommunicationResult(env, -1);
    std::vector<char> text(length + 1);
    napi_get_value_string_utf8(env, arg, text.data(), text.size(), &length);
    return CommunicationResult(env, rust_send_chat_message(text.data()));
}
static napi_value TakeChatMessages(napi_env env, napi_callback_info) {
    char* text = rust_take_chat_messages();
    napi_value ret;
    napi_create_string_utf8(env, text ? text : "[]", NAPI_AUTO_LENGTH, &ret);
    rust_free_string(text);
    return ret;
}
static napi_value RequestVoiceCall(napi_env env, napi_callback_info) {
    return CommunicationResult(env, rust_request_voice_call());
}
static napi_value VoiceCallState(napi_env env, napi_callback_info) {
    return CommunicationResult(env, rust_voice_call_state());
}
static napi_value EndVoiceCall(napi_env env, napi_callback_info) {
    int result = rust_end_voice_call();
    VoiceCapture::instance().stop();
    return CommunicationResult(env, result);
}
static napi_value StartVoiceCapture(napi_env env, napi_callback_info) {
    return CommunicationResult(env, VoiceCapture::instance().start());
}
static napi_value StopVoiceCapture(napi_env env, napi_callback_info) {
    VoiceCapture::instance().stop();
    return CommunicationResult(env, 0);
}
