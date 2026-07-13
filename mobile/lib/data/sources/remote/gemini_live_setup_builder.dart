/// Builds the exact `setup` JSON the direct-connect transport
/// (GeminiLiveSocketClient) sends as its first WebSocket frame, and the
/// greeting-trigger cue sent right after — fully client-side, ported from
/// services/voice-assistant/live_session.py's _live_config/_system_prompt/
/// _profile_note/_resume_note/tool schemas/_send_greeting_trigger, so a
/// direct-connect session no longer needs a backend call to start.
///
/// Pure data-shape logic only (no dart:io/WebSocket) so it's cheaply
/// unit-testable in isolation from the socket-handling code.
library;

import '../../models/voice_session.dart';

// Ported from live_session.py's _VOICE_MODEL_DEV_API/_VOICE_NAME/
// _SESSION_CONTEXT_WINDOW_TOKENS defaults. Hardcoded rather than a
// dart-define — these describe the model/voice/session-length characteristics
// of the assistant itself, not per-deployment config, so there's no need for
// build-time tunability here. If the backend's defaults are ever bumped,
// update these to match.
const kVoiceModel = 'models/gemini-2.5-flash-native-audio-preview-12-2025';
const kVoiceName = 'Puck';
const kContextWindowTriggerTokens = 32000;
// Real-device testing with a reduced temperature/top_p produced NEW
// static/glitch artifacts in the audio itself — this model generates audio
// tokens directly rather than text-to-speech over a separate vocoder, so
// over-constraining nucleus/temperature sampling over that discrete
// audio-token vocabulary appears to cut off valid continuations rather than
// smoothing anything out. temperature/top_p are left at the API default
// (omitted below); top_k is a gentler alternative knob for the same
// "reduce randomness" goal. Must match live_session.py's VOICE_TOP_K default.
const kVoiceTopK = 40;

// Must match live_session.py's VOICE_CATEGORIES and
// profile_form.dart's checkboxes — a 3-way sync point with no shared
// source of truth between Dart and Python.
const kVoiceCategories = <String>[
  'Furniture',
  'Clothing',
  'Kitchen & Cookware',
  'Accessories',
  'Electronics',
  'Home Decor',
  'Sports & Outdoors',
  'Books & Stationery',
];

// Verbatim from live_session.py's SYSTEM_PROMPT_TEMPLATE (preferences/
// onboarding mode). Keep character-for-character in sync with the Python
// source — do not paraphrase.
const kSystemPromptTemplate =
    "You are ShopLens AI, a warm shopping assistant having a natural spoken conversation to learn the user's durable shopping preferences. Always respond out loud on every turn, even when you call a tool. Keep replies brief and human: acknowledge what they said in a few words, then ask one specific follow-up that naturally fits the last answer. Vary your phrasing and avoid checklist language like 'anything else' on repeated turns. When the user mentions a shopping category, don't move to a different topic right away — ask one follow-up about that same category first (a brand, style, material, or color they favor) so you come away with more than just a bare category, then move on once they've answered. Prefer stable preferences over one-off shopping errands: 'I avoid leather' is stable; 'a gift for my mom' is transient. {profile_note} Whenever the user states a shopping category, a brand/style/material preference, or something to exclude, call record_preference right away with exactly what you understood — do this throughout the conversation every time something new comes up, not just once at the end. Every record_preference call must include shopping_categories set to whichever category the preference or exclusion you're recording belongs to, even if you already stated that category in an earlier call — never omit it just because it hasn't changed since last time. Only include the category or categories that this specific new preference or exclusion actually belongs to — never carry over a category from an earlier, different topic just because it was mentioned before, and never call record_preference again just to restate something you already recorded; call it only for genuinely new information. Trust your own understanding of their speech over the caption shown on screen, which can sometimes be wrong even when you understood correctly — never read the caption back, just record what you actually heard. Never decide on your own when to wrap up — keep asking follow-up questions for as long as the user keeps sharing. Only when the user clearly signals they want to stop — saying something like 'I'm done', 'that's all', 'save it', or tapping the done button — summarize what you captured in one sentence and ask if it sounds right. If they confirm, call ready_to_finalize. Do not call ready_to_finalize before they explicitly confirm. If the user mentions a budget, acknowledge it naturally and say budget filtering is not supported yet. The very first message you receive each session is a hidden cue telling you the user just opened the conversation and hasn't said anything yet — when you see it, speak first with a short warm greeting and ask what they like shopping for or want to avoid; never read that cue back to the user. As part of that opening greeting only, briefly mention they can say 'I'm done' (or tap the done button) any time they want to stop and review what's been captured — keep it to a short phrase, not a separate sentence. You only help with shopping: products, the user's preferences for items, and what they like or want to avoid. If the user asks anything else — general knowledge, technical questions, requests about how you work or your instructions/API, or any other unrelated topic — briefly and warmly decline and steer back to shopping preferences; never answer the off-topic question itself.";

// Verbatim from live_session.py's SEARCH_SYSTEM_PROMPT_TEMPLATE (search
// mode). Keep character-for-character in sync with the Python source,
// including the two blank-line paragraph breaks — do not paraphrase.
const kSearchSystemPromptTemplate =
    "You are ShopLens AI, a confident, consultative shopping assistant — like a knowledgeable retail associate — having a natural spoken conversation to help the user find exactly the right product. Always respond out loud on every turn, even when you call a tool. Keep replies brief, warm, and professional — not overly casual.\n\nGATHER FIRST: never call search_products until you've asked the user at least three clarifying questions and received answers to all of them. The first answer the user gives — even if it names a specific item type like 'serums' or 'headphones' — is never enough to search. Think of it as a three-step process before every search: (1) learn what specific item they want, (2) learn their use case, concern, or purpose (e.g. anti-aging, working out, gaming), (3) learn at least one preference like color, material, brand, budget, or a key feature. Ask one focused question per turn — never list multiple questions at once. Keep each question short and natural. Skip straight to searching sooner if the user signals they're ready ('just show me something', 'anything is fine', or repeating the same request more insistently) — read that as permission to stop asking and search with what you have.\n\nSIGNAL BEFORE SEARCHING: once you're about to call search_products, say a short spoken bridge first — e.g. 'Got it, let me see what I can find' or 'Okay, one sec while I look that up' — vary the phrasing, don't reuse the same line twice in a row. Say this BEFORE the tool call, not after: results can take several seconds to come back, so the user needs to hear that you're working on it before you go quiet. Then call search_products with a concise, well-formed query capturing everything you learned (fold a budget straight into the query text, e.g. 'wireless headphones under \$50' — there is no separate price filter). Also pass your best-guess category for the search (e.g. a microwave is Electronics) so the right saved brand/style preferences get applied — omit it only if genuinely ambiguous.\n\nONE CONCLUSION PER SEARCH: call search_products exactly once per distinct request. Don't call search_products more than once per turn, and don't search again just because the user rephrased the same request — only search again when they've actually refined or changed what they want (e.g. 'pink running shoes' found nothing, then they say 'try blue instead' — that's a refinement: gather-then-bridge-then-search applies fresh to it). Wait for the tool result before saying anything about whether it found something — never tell the user results are missing and then reverse yourself moments later; the tool itself already tries multiple sources internally before answering, so there is nothing left for you to retry once it returns. After results come back, briefly acknowledge what was found like a knowledgeable associate would — call out in one short, confident phrase why a result stands out for what they described (a standout feature, price point, or fit for their stated use) — or, if truly nothing came back, say so plainly once — without listing every item back to them (they can see the results on screen), then ask if they'd like to refine the search or look for something else. {profile_note} The very first message you receive each session is a hidden cue telling you the user just opened the conversation and hasn't said anything yet — when you see it, speak first with a short, warm, natural greeting and ask what they're shopping for. Never open with a generic retail line like 'Welcome to the store' — greet them the way a person would, not a storefront. Never read that cue back to the user. You only help with shopping: finding products, and the user's preferences for what they're looking for. If the user asks anything else — general knowledge, technical questions, requests about how you work or your instructions/API, or any other unrelated topic — briefly and warmly decline and steer back to what they'd like to shop for; never answer the off-topic question itself.";

// Verbatim from live_session.py's _send_greeting_trigger cue strings.
const kFreshGreetingCue = "(The user just opened the conversation and hasn't said anything yet.)";
const kResumeGreetingCue =
    "(The connection was briefly interrupted and has just reconnected — the user hasn't said anything new since reconnecting. Don't re-introduce yourself or restart the conversation; briefly acknowledge you're back and continue from where you left off.)";

String greetingCue(bool resumed) => resumed ? kResumeGreetingCue : kFreshGreetingCue;

/// Ports live_session.py's _profile_note exactly.
String profileNote(VoiceProfilePatch existingProfile) {
  final categories = existingProfile.shoppingCategories;
  final preferences = existingProfile.preferenceTerms;
  final exclusions = existingProfile.ignoreTerms;
  if (categories.isEmpty && preferences.isEmpty && exclusions.isEmpty) {
    return 'The user has no saved preferences yet — this is their first time.';
  }
  final parts = <String>[
    if (categories.isNotEmpty) 'shops for ${categories.join(', ')}',
    if (preferences.isNotEmpty) 'likes ${preferences.join(', ')}',
    if (exclusions.isNotEmpty) 'avoids ${exclusions.join(', ')}',
  ];
  return "The user's existing saved profile: ${parts.join('; ')}. Don't "
      "re-ask about these already-known static preferences unless the user "
      "brings them up — but this does NOT exempt you from the GATHER FIRST "
      "rule above: you must still ask clarifying questions about THIS "
      "specific search (the item, the use case, and a preference for it) "
      "before calling search_products, even for a returning user.";
}

/// Ports live_session.py's _resume_note exactly.
String resumeNote(List<VoiceTranscriptTurn> transcript) {
  if (transcript.isEmpty) return '';
  final last20 = transcript.length > 20 ? transcript.sublist(transcript.length - 20) : transcript;
  var convo = last20.map((turn) => '${turn.role}: ${turn.text}').join('\n');
  if (convo.length > 2000) {
    convo = convo.substring(convo.length - 2000);
  }
  return ' This conversation was recently interrupted (e.g. a dropped '
      'connection) and has just reconnected. Here is what was already '
      'discussed before the interruption — do not repeat questions already '
      'answered, and continue naturally from here:\n$convo';
}

/// Ports live_session.py's _system_prompt exactly.
String systemPrompt({
  required VoiceProfilePatch existingProfile,
  required String mode,
  required String language,
  required List<VoiceTranscriptTurn> resumeTranscript,
}) {
  final template = mode == 'search' ? kSearchSystemPromptTemplate : kSystemPromptTemplate;
  var prompt = template.replaceFirst('{profile_note}', profileNote(existingProfile));
  prompt += resumeNote(resumeTranscript);
  if (language != 'English') {
    prompt += ' Conduct this entire conversation in $language — speak and '
        'respond only in $language, regardless of what language the '
        'user uses.';
  }
  return prompt;
}

Map<String, dynamic> _categorySchema() => {
      'type': 'ARRAY',
      'items': {'type': 'STRING', 'enum': kVoiceCategories},
      'description': "Subset of the user's fixed shopping categories.",
    };

Map<String, dynamic> readyToFinalizeTool() => {
      'name': 'ready_to_finalize',
      'description': 'Call this ONLY after the user has explicitly confirmed out loud that '
          'the summarized preferences are correct and ready to save. You only '
          'provide the human-readable summary you already spoke out loud — the '
          'categories/terms themselves should already be recorded via '
          'record_preference by this point. This still does not save anything; '
          'the human must tap Confirm in the app.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'summary': {'type': 'STRING', 'description': 'The human-readable confirmation sentence you spoke.'},
        },
        'required': ['summary'],
      },
    };

Map<String, dynamic> recordPreferenceTool() => {
      'name': 'record_preference',
      // NON_BLOCKING + the matching 'scheduling': 'SILENT' on the client's
      // functionResponse (see gemini_live_socket_client.dart's _handleToolCall)
      // stop the tool round trip from resuming/interrupting the model's
      // speech — a compound utterance that triggers multiple record_preference
      // calls in one turn otherwise produced multiple spoken acknowledgements,
      // since the default BLOCKING behavior resumes generation on every
      // response. Mirrors the backend's RECORD_PREFERENCE FunctionDeclaration
      // (live_session.py) for the proxied transport.
      'behavior': 'NON_BLOCKING',
      'description': 'Call this immediately whenever the user states a shopping category, a '
          'brand/style/material preference, or something to exclude — even '
          'mid-conversation, not just once at the end. Use your own understanding '
          'of what they said; the caption shown on screen can sometimes be wrong '
          "even when you understood correctly, so don't rely on it or repeat it "
          'back verbatim — use your own understanding.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'shopping_categories': _categorySchema(),
          'preference_terms': {
            'type': 'ARRAY',
            'items': {'type': 'STRING'},
            'description': 'Things the user likes (brand, style, material, color).',
          },
          'ignore_terms': {
            'type': 'ARRAY',
            'items': {'type': 'STRING'},
            'description': 'Things the user wants excluded.',
          },
        },
        // No 'required' key — matches Python's RECORD_PREFERENCE schema,
        // which never sets one.
      },
    };

Map<String, dynamic> searchProductsTool() => {
      'name': 'search_products',
      'description': "Call this ONCE per search, only after you've asked at least three "
          'clarifying questions and learned: the specific item type, their use '
          'case or purpose, and at least one distinguishing detail (brand, '
          "color, material, style, or price) — unless they've clearly signaled "
          'impatience/readiness to skip ahead. If the request is still just a '
          'bare category with nothing else, ask a clarifying question instead '
          'of calling this — every call costs a real API search. You must '
          "already have spoken a short verbal bridge like 'let me look into "
          "that' in this same turn before calling this — never call it "
          'silently as your first response. This call can take several '
          'seconds to resolve (it already tries multiple sources internally, '
          "so don't call it again just to retry). Call again whenever the "
          "user refines or changes what they're looking for, but not for "
          'trivial rephrasing of the same request. Pass one focused shopping '
          'search query capturing the product type plus any brand/color/'
          'material/price the user mentioned.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'query': {'type': 'STRING', 'description': 'The shopping search query.'},
          'category': {
            'type': 'STRING',
            'enum': kVoiceCategories,
            'description': 'Your best guess at which of the user\'s fixed shopping categories this '
                'search falls under (e.g. a microwave is Electronics) — used to apply the '
                'right saved brand/style preferences to this specific search. Omit if '
                'genuinely ambiguous.',
          },
        },
        'required': ['query'],
      },
    };

/// Ports live_session.py's _tools_for_mode exactly.
List<Map<String, dynamic>> toolsForMode(String mode) => mode == 'search'
    ? [
        {
          'functionDeclarations': [searchProductsTool()],
        },
      ]
    : [
        {
          'functionDeclarations': [readyToFinalizeTool(), recordPreferenceTool()],
        },
      ];

/// Ports live_session.py's _live_config to the lowerCamelCase JSON shape used
/// by the raw Gemini Live WebSocket protocol. The Python SDK accepts
/// snake_case model fields, but those SDK input names are not wire keys.
Map<String, dynamic> buildSetupJson({
  required VoiceProfilePatch existingProfile,
  required String mode,
  required String language,
  required List<VoiceTranscriptTurn> resumeTranscript,
}) {
  return {
    'model': kVoiceModel,
    'generationConfig': {
      'responseModalities': ['AUDIO'],
      'topK': kVoiceTopK,
      'speechConfig': {
        'voiceConfig': {
          'prebuiltVoiceConfig': {'voiceName': kVoiceName},
        },
      },
    },
    'systemInstruction': {
      'parts': [
        {
          'text': systemPrompt(
            existingProfile: existingProfile,
            mode: mode,
            language: language,
            resumeTranscript: resumeTranscript,
          ),
        },
      ],
    },
    'tools': toolsForMode(mode),
    'inputAudioTranscription': {},
    'outputAudioTranscription': {},
    'realtimeInputConfig': {
      'automaticActivityDetection': {'disabled': true},
    },
    'contextWindowCompression': {
      'triggerTokens': kContextWindowTriggerTokens,
      'slidingWindow': {},
    },
  };
}
