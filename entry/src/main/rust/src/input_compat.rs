//! Per-session input compatibility. Do not change the normal OS Map tables for KVMs.
use hbb_common::message_proto::{key_event, ControlKey, KeyEvent, KeyboardMode};

pub fn is_one_kvm(username: &str, displays: &[String]) -> bool {
    username.trim().eq_ignore_ascii_case("one-kvm")
        && displays.iter().any(|name| name.eq_ignore_ascii_case("KVM Display"))
}

pub fn mapped_modifier(code: i32, platform: &str) -> Option<u32> {
    // Windows scan code, Xorg keycode, Android keycode, macOS virtual keycode.
    let codes = match code {
        16 => [0x2a, 50, 59, 56], 161 => [0x36, 62, 60, 60],
        17 => [0x1d, 37, 113, 59], 163 => [0xe01d, 105, 114, 62],
        18 => [0x38, 64, 57, 58], 165 => [0xe038, 108, 58, 61],
        91 => [0xe05b, 133, 117, 55], 92 => [0xe05c, 134, 118, 54],
        20 => [0x3a, 66, 115, 57],
        _ => return None,
    };
    let p = platform.to_ascii_lowercase();
    Some(codes[if p.contains("linux") { 1 } else if p.contains("android") { 2 }
        else if p.contains("mac") || p.contains("darwin") || p.contains("osx") { 3 } else { 0 }])
}

pub fn legacy_physical_key(hid: u32, action: i32, modifiers: i32) -> Option<KeyEvent> {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Legacy.into(),
        modifiers: super::modifier_mask_to_controls(modifiers),
        ..Default::default()
    };
    // Use characters, NOT OS scan codes. Preserve modifiers for shortcuts and USB HID.
    let ch = match hid {
        0x04..=0x1d => Some(b'a' as u32 + hid - 4),
        0x1e..=0x26 => Some(b'1' as u32 + hid - 0x1e),
        0x27 => Some(b'0' as u32),
        0x2c => Some(b' ' as u32),
        0x2d..=0x38 => Some(b"-=[]\\#;'`,./"[(hid - 0x2d) as usize] as u32),
        _ => None,
    };
    if let Some(ch) = ch {
        // Unicode disambiguates punctuation from legacy VK/control codes in KVM adapters.
        event.union = Some(if hid >= 0x2d {
            key_event::Union::Unicode(ch)
        } else {
            key_event::Union::Chr(ch)
        });
        return Some(event);
    }
    let control = match hid {
        0x28 => ControlKey::Return, 0x29 => ControlKey::Escape,
        0x2a => ControlKey::Backspace, 0x2b => ControlKey::Tab,
        0x39 => ControlKey::CapsLock,
        0x3a => ControlKey::F1, 0x3b => ControlKey::F2, 0x3c => ControlKey::F3,
        0x3d => ControlKey::F4, 0x3e => ControlKey::F5, 0x3f => ControlKey::F6,
        0x40 => ControlKey::F7, 0x41 => ControlKey::F8, 0x42 => ControlKey::F9,
        0x43 => ControlKey::F10, 0x44 => ControlKey::F11, 0x45 => ControlKey::F12,
        0x49 => ControlKey::Insert, 0x4a => ControlKey::Home, 0x4b => ControlKey::PageUp,
        0x4c => ControlKey::Delete, 0x4d => ControlKey::End, 0x4e => ControlKey::PageDown,
        0x4f => ControlKey::RightArrow, 0x50 => ControlKey::LeftArrow,
        0x51 => ControlKey::DownArrow, 0x52 => ControlKey::UpArrow,
        _ => return None,
    };
    event.union = Some(key_event::Union::ControlKey(control.into()));
    Some(event)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn kvm_detection_is_narrow() {
        assert!(is_one_kvm("one-kvm", &["KVM Display".into()]));
        assert!(!is_one_kvm("someone", &["KVM Display".into()]));
        assert!(!is_one_kvm("one-kvm", &["Display 1".into()]));
    }
    #[test]
    fn d_is_character_not_windows_space_scan_code() {
        let event = legacy_physical_key(7, 0, 3).unwrap();
        assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Legacy);
        assert!(matches!(event.union, Some(key_event::Union::Chr(100))));
        assert_eq!(event.modifiers.len(), 2);
        assert!(event.down);
        assert!(!legacy_physical_key(7, 1, 0).unwrap().down);
    }
    #[test]
    fn punctuation_and_controls_do_not_alias() {
        assert!(matches!(legacy_physical_key(0x2f, 0, 0).unwrap().union,
            Some(key_event::Union::Unicode(91))));
        assert!(matches!(legacy_physical_key(0x28, 0, 0).unwrap().union,
            Some(key_event::Union::ControlKey(_))));
        assert!(legacy_physical_key(0xffff, 0, 0).is_none());
    }
    #[test]
    fn explicit_map_modifiers_follow_target_platform() {
        assert_eq!(mapped_modifier(16, "Windows"), Some(0x2a));
        assert_eq!(mapped_modifier(163, "Linux"), Some(105));
        assert_eq!(mapped_modifier(91, "Mac OS"), Some(55));
        assert_eq!(mapped_modifier(20, "Android"), Some(115));
        assert_eq!(mapped_modifier(13, "Windows"), None);
    }
}
