use hbb_common::message_proto::ImageQuality;

#[derive(Clone, Copy, Debug)]
pub(crate) struct PerformanceConfig {
    pub fps: i32,
    pub quality: ImageQuality,
    // Percentage, not kbps. RustDesk's wire format stores this in the high bits.
    pub custom_quality: i32,
}

impl PerformanceConfig {
    pub const DEFAULT: Self = Self { fps: 45, quality: ImageQuality::Low, custom_quality: 0 };

    pub fn from_preset(preset: &str) -> Self {
        let (fps, quality) = match preset {
            "stable" => (30, ImageQuality::Balanced),
            "high_fps" => (60, ImageQuality::Balanced),
            "silky" => (60, ImageQuality::Low),
            "best" => (30, ImageQuality::Best),
            _ => {
                let parts: Vec<&str> = preset.split(':').collect();
                if parts.len() == 3 && parts[0] == "custom"
                    && (1..=4).contains(&parts[1].len()) && (1..=3).contains(&parts[2].len())
                    && parts[1].bytes().all(|v| v.is_ascii_digit())
                    && parts[2].bytes().all(|v| v.is_ascii_digit()) {
                    if let (Ok(quality), Ok(fps)) = (parts[1].parse::<i32>(), parts[2].parse::<i32>()) {
                        return Self { fps: fps.clamp(5, 120), quality: ImageQuality::NotSet,
                            custom_quality: quality.clamp(10, 2000) };
                    }
                }
                return Self::DEFAULT;
            }
        };
        Self { fps, quality, custom_quality: 0 }
    }

    pub fn effective(self, background: bool, public_relay: bool) -> Self {
        if background {
            return Self { fps: 2, ..Self::DEFAULT };
        }
        if public_relay && self.custom_quality > 0 {
            // Match upstream LoginConfigHandler::get_option_message.
            return Self { fps: self.fps.min(30),
                custom_quality: if self.custom_quality > 100 { 50 } else { self.custom_quality }, ..self };
        }
        self
    }

    pub fn wire_quality(self) -> i32 { self.custom_quality << 8 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_and_invalid_inputs() {
        assert_eq!(PerformanceConfig::from_preset("best").quality, ImageQuality::Best);
        for (name, fps) in [("stable", 30), ("high_fps", 60), ("smooth", 45), ("silky", 60)] {
            let p = PerformanceConfig::from_preset(name);
            assert_eq!(p.fps, fps);
            assert_eq!(p.wire_quality(), 0);
        }
        for invalid in ["custom", "custom:NaN:60", "custom:-1:30", "custom:100:60:1", "custom:999999:30", "custom::30"] {
            assert_eq!(PerformanceConfig::from_preset(invalid).quality, ImageQuality::Low);
        }
    }

    #[test]
    fn custom_protocol_and_limits() {
        let p = PerformanceConfig::from_preset("custom:2000:120");
        assert_eq!(p.quality, ImageQuality::NotSet);
        assert_eq!(p.wire_quality(), 2000 << 8);
        assert_eq!(p.fps, 120);
        let min = PerformanceConfig::from_preset("custom:0:0");
        assert_eq!((min.custom_quality, min.fps), (10, 5));
        let max = PerformanceConfig::from_preset("custom:9999:999");
        assert_eq!((max.custom_quality, max.fps), (2000, 120));
    }

    #[test]
    fn public_relay_and_background_do_not_destroy_saved_quality() {
        let p = PerformanceConfig::from_preset("custom:500:60");
        let relay = p.effective(false, true);
        assert_eq!((relay.custom_quality, relay.fps), (50, 30));
        let bg = p.effective(true, false);
        assert_eq!((bg.custom_quality, bg.fps, bg.quality), (0, 2, ImageQuality::Low));
        let restored = p.effective(false, false);
        assert_eq!((restored.custom_quality, restored.fps), (500, 60));
        let low = PerformanceConfig::from_preset("custom:80:20").effective(false, true);
        assert_eq!((low.custom_quality, low.fps), (80, 20));
    }
}
