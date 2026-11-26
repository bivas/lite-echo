"""The languages Whisper can transcribe: code, English name and native name.

The code set is exactly the one faster-whisper accepts (``faster_whisper.tokenizer._LANGUAGE_CODES``);
a unit test keeps the two in sync. Stdlib only, so ``engine-info`` stays fast.
"""
from __future__ import annotations

# code: (English name, native name)
LANGUAGES: dict[str, tuple[str, str]] = {
    "af": ("Afrikaans", "Afrikaans"),
    "am": ("Amharic", "አማርኛ"),
    "ar": ("Arabic", "العربية"),
    "as": ("Assamese", "অসমীয়া"),
    "az": ("Azerbaijani", "Azərbaycanca"),
    "ba": ("Bashkir", "Башҡортса"),
    "be": ("Belarusian", "Беларуская"),
    "bg": ("Bulgarian", "Български"),
    "bn": ("Bengali", "বাংলা"),
    "bo": ("Tibetan", "བོད་སྐད"),
    "br": ("Breton", "Brezhoneg"),
    "bs": ("Bosnian", "Bosanski"),
    "ca": ("Catalan", "Català"),
    "cs": ("Czech", "Čeština"),
    "cy": ("Welsh", "Cymraeg"),
    "da": ("Danish", "Dansk"),
    "de": ("German", "Deutsch"),
    "el": ("Greek", "Ελληνικά"),
    "en": ("English", "English"),
    "es": ("Spanish", "Español"),
    "et": ("Estonian", "Eesti"),
    "eu": ("Basque", "Euskara"),
    "fa": ("Persian", "فارسی"),
    "fi": ("Finnish", "Suomi"),
    "fo": ("Faroese", "Føroyskt"),
    "fr": ("French", "Français"),
    "gl": ("Galician", "Galego"),
    "gu": ("Gujarati", "ગુજરાતી"),
    "ha": ("Hausa", "Hausa"),
    "haw": ("Hawaiian", "ʻŌlelo Hawaiʻi"),
    "he": ("Hebrew", "עברית"),
    "hi": ("Hindi", "हिन्दी"),
    "hr": ("Croatian", "Hrvatski"),
    "ht": ("Haitian Creole", "Kreyòl ayisyen"),
    "hu": ("Hungarian", "Magyar"),
    "hy": ("Armenian", "Հայերեն"),
    "id": ("Indonesian", "Bahasa Indonesia"),
    "is": ("Icelandic", "Íslenska"),
    "it": ("Italian", "Italiano"),
    "ja": ("Japanese", "日本語"),
    "jw": ("Javanese", "Basa Jawa"),
    "ka": ("Georgian", "ქართული"),
    "kk": ("Kazakh", "Қазақ тілі"),
    "km": ("Khmer", "ខ្មែរ"),
    "kn": ("Kannada", "ಕನ್ನಡ"),
    "ko": ("Korean", "한국어"),
    "la": ("Latin", "Latina"),
    "lb": ("Luxembourgish", "Lëtzebuergesch"),
    "ln": ("Lingala", "Lingála"),
    "lo": ("Lao", "ລາວ"),
    "lt": ("Lithuanian", "Lietuvių"),
    "lv": ("Latvian", "Latviešu"),
    "mg": ("Malagasy", "Malagasy"),
    "mi": ("Maori", "Te reo Māori"),
    "mk": ("Macedonian", "Македонски"),
    "ml": ("Malayalam", "മലയാളം"),
    "mn": ("Mongolian", "Монгол"),
    "mr": ("Marathi", "मराठी"),
    "ms": ("Malay", "Bahasa Melayu"),
    "mt": ("Maltese", "Malti"),
    "my": ("Burmese", "မြန်မာ"),
    "ne": ("Nepali", "नेपाली"),
    "nl": ("Dutch", "Nederlands"),
    "nn": ("Norwegian Nynorsk", "Nynorsk"),
    "no": ("Norwegian", "Norsk"),
    "oc": ("Occitan", "Occitan"),
    "pa": ("Punjabi", "ਪੰਜਾਬੀ"),
    "pl": ("Polish", "Polski"),
    "ps": ("Pashto", "پښتو"),
    "pt": ("Portuguese", "Português"),
    "ro": ("Romanian", "Română"),
    "ru": ("Russian", "Русский"),
    "sa": ("Sanskrit", "संस्कृतम्"),
    "sd": ("Sindhi", "سنڌي"),
    "si": ("Sinhala", "සිංහල"),
    "sk": ("Slovak", "Slovenčina"),
    "sl": ("Slovenian", "Slovenščina"),
    "sn": ("Shona", "chiShona"),
    "so": ("Somali", "Soomaali"),
    "sq": ("Albanian", "Shqip"),
    "sr": ("Serbian", "Српски"),
    "su": ("Sundanese", "Basa Sunda"),
    "sv": ("Swedish", "Svenska"),
    "sw": ("Swahili", "Kiswahili"),
    "ta": ("Tamil", "தமிழ்"),
    "te": ("Telugu", "తెలుగు"),
    "tg": ("Tajik", "Тоҷикӣ"),
    "th": ("Thai", "ไทย"),
    "tk": ("Turkmen", "Türkmençe"),
    "tl": ("Tagalog", "Tagalog"),
    "tr": ("Turkish", "Türkçe"),
    "tt": ("Tatar", "Татарча"),
    "uk": ("Ukrainian", "Українська"),
    "ur": ("Urdu", "اردو"),
    "uz": ("Uzbek", "Oʻzbekcha"),
    "vi": ("Vietnamese", "Tiếng Việt"),
    "yi": ("Yiddish", "ייִדיש"),
    "yo": ("Yoruba", "Yorùbá"),
    "yue": ("Cantonese", "粵語"),
    "zh": ("Chinese", "中文"),
}

RTL = frozenset({"he", "ar", "fa", "ur", "yi"})

# Extra English spellings accepted on the command line.
_ALIASES = {
    "mandarin": "zh", "castilian": "es", "valencian": "ca", "flemish": "nl", "haitian": "ht",
    "letzeburgesch": "lb", "pushto": "ps", "panjabi": "pa", "moldavian": "ro", "moldovan": "ro",
    "sinhalese": "si", "myanmar": "my", "farsi": "fa", "nynorsk": "nn", "bokmal": "no",
}


def name(code: str) -> str:
    """English name for a code (the code itself if unknown)."""
    return LANGUAGES.get(code, (code, code))[0]


def direction(code: str) -> str:
    return "rtl" if code in RTL else "ltr"


def lookup(value: str) -> str | None:
    """Map a code or English name (case-insensitive) to a code; None if unknown."""
    key = value.strip().lower()
    if key in LANGUAGES:
        return key
    for code, (english, _native) in LANGUAGES.items():
        if english.lower() == key:
            return code
    return _ALIASES.get(key)


def catalog(tuned: set[str] | frozenset[str] = frozenset()) -> list[dict]:
    """`engine-info` list: [{"code", "name", "native", "tuned"}], sorted by English name."""
    return sorted(({"code": c, "name": n, "native": nat, "tuned": c in tuned}
                   for c, (n, nat) in LANGUAGES.items()), key=lambda d: d["name"])
