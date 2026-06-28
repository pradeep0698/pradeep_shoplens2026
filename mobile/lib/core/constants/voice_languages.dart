// Gemini Live's native-audio output (gemini-live-2.5-flash-native-audio,
// see services/voice-assistant/live_session.py's VOICE_MODEL) auto-detects
// spoken language and ignores SpeechConfig.language_code, so this list must
// match live_session.py's SUPPORTED_LANGUAGES exactly — the backend steers
// language via a system-instruction directive built from the display name
// sent here, not via a language code.
const kVoiceLanguages = [
  'Afrikaans', 'Akan', 'Albanian', 'Amharic', 'Arabic', 'Armenian', 'Assamese',
  'Azerbaijani', 'Basque', 'Belarusian', 'Bengali', 'Bosnian', 'Bulgarian',
  'Burmese', 'Catalan', 'Cebuano', 'Chinese', 'Croatian', 'Czech', 'Danish',
  'Dutch', 'English', 'Estonian', 'Faroese', 'Filipino', 'Finnish', 'French',
  'Galician', 'Georgian', 'German', 'Greek', 'Gujarati', 'Hausa', 'Hebrew',
  'Hindi', 'Hungarian', 'Icelandic', 'Indonesian', 'Irish', 'Italian',
  'Japanese', 'Kannada', 'Kazakh', 'Khmer', 'Kinyarwanda', 'Korean', 'Kurdish',
  'Kyrgyz', 'Lao', 'Latvian', 'Lithuanian', 'Macedonian', 'Malay', 'Malayalam',
  'Maltese', 'Maori', 'Marathi', 'Mongolian', 'Nepali', 'Norwegian', 'Odia',
  'Oromo', 'Pashto', 'Persian', 'Polish', 'Portuguese', 'Punjabi', 'Quechua',
  'Romanian', 'Romansh', 'Russian', 'Serbian', 'Sindhi', 'Sinhala', 'Slovak',
  'Slovenian', 'Somali', 'Southern Sotho', 'Spanish', 'Swahili', 'Swedish',
  'Tajik', 'Tamil', 'Telugu', 'Thai', 'Tswana', 'Turkish', 'Turkmen',
  'Ukrainian', 'Urdu', 'Uzbek', 'Vietnamese', 'Welsh', 'Western Frisian',
  'Wolof', 'Yoruba', 'Zulu',
];
