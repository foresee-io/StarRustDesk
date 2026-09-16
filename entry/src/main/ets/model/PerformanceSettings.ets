// Keep quality settings in the existing preset field so saved connections,
// encrypted backups and cloud sync retain them without a schema migration.
export class PerformanceSettings {
  static custom(bitrate: number, fps: number): string {
    const quality: number = Number.isFinite(bitrate) ? Math.round(Math.max(10, Math.min(2000, bitrate))) : 100
    const frameRate: number = Number.isFinite(fps) ? Math.round(Math.max(5, Math.min(120, fps))) : 30
    return `custom:${quality}:${frameRate}`
  }

  static normalize(value: string): string {
    if (value === 'stable' || value === 'high_fps' || value === 'smooth' || value === 'silky' || value === 'best') {
      return value
    }
    if (/^custom:\d{1,4}:\d{1,3}$/.test(value)) {
      const parts: string[] = value.split(':')
      return PerformanceSettings.custom(Number(parts[1]), Number(parts[2]))
    }
    return 'smooth'
  }

  static isCustom(value: string): boolean {
    return PerformanceSettings.normalize(value).startsWith('custom:')
  }

  static bitrate(value: string): number {
    const normalized: string = PerformanceSettings.normalize(value)
    return normalized.startsWith('custom:') ? Number(normalized.split(':')[1]) : 100
  }

  static fps(value: string): number {
    const normalized: string = PerformanceSettings.normalize(value)
    return normalized.startsWith('custom:') ? Number(normalized.split(':')[2]) : 30
  }
}
