import { i18n } from '@kit.LocalizationKit'
import { RustDeskNapi } from '../service/RustDeskNapi'
import { resolveLanguage } from './I18n'

export const LANGUAGE_OPTION: string = 'ui-language'

export class LanguageService {
  static initialize(): void {
    const stored: string = RustDeskNapi.getOption(LANGUAGE_OPTION)
    const preference: string = LanguageService.validPreference(stored)
    AppStorage.setOrCreate('uiLanguagePreference', preference)
    LanguageService.applyResourceLanguage(preference)
    LanguageService.refreshSystemLanguage()
  }

  static setPreference(preference: string): void {
    const value: string = LanguageService.validPreference(preference)
    RustDeskNapi.setOption(LANGUAGE_OPTION, value)
    AppStorage.setOrCreate('uiLanguagePreference', value)
    LanguageService.applyResourceLanguage(value)
    LanguageService.refreshSystemLanguage()
    // Preference only, never input text or remote connection data.
    RustDeskNapi.appendDiagnosticLog('language', `preference_changed value=${value}`)
  }

  static refreshSystemLanguage(): void {
    const preference: string = AppStorage.get<string>('uiLanguagePreference') ?? 'system'
    let systemLanguage: string = 'en'
    try { systemLanguage = i18n.System.getSystemLanguage() } catch (_error) {}
    AppStorage.setOrCreate('uiLanguage', resolveLanguage(preference, systemLanguage))
  }

  private static validPreference(value: string): string {
    return value === 'zh-Hans' || value === 'zh-Hant' || value === 'en' ? value : 'system'
  }

  private static applyResourceLanguage(preference: string): void {
    // Permission/system resource text uses the same preference on next cold start.
    // Live ArkUI text is updated separately without rebuilding the video surface.
    try { i18n.System.setAppPreferredLanguage(preference === 'system' ? 'default' : preference) } catch (_error) {}
  }
}
