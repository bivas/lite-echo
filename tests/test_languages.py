import pytest

from liteecho import languages
from liteecho.info import gather
from liteecho.prompts import load
from liteecho.resources import package_prompts_dir


def test_codes_match_faster_whisper():
    from faster_whisper.tokenizer import _LANGUAGE_CODES
    assert set(languages.LANGUAGES) == set(_LANGUAGE_CODES)
    assert len(languages.LANGUAGES) == 100


def test_names_are_filled_and_unique():
    english = [n for n, _ in languages.LANGUAGES.values()]
    assert all(n.strip() for n in english) and len(set(english)) == len(english)
    assert all(nat.strip() for _, nat in languages.LANGUAGES.values())
    assert languages.LANGUAGES["he"] == ("Hebrew", "עברית")


@pytest.mark.parametrize("value,code", [("he", "he"), ("HE", "he"), ("hebrew", "he"), ("German", "de"),
                                        ("haw", "haw"), ("Cantonese", "yue"), ("norwegian", "no"),
                                        ("Mandarin", "zh"), (" en ", "en")])
def test_lookup(value, code):
    assert languages.lookup(value) == code


@pytest.mark.parametrize("value", ["xx", "", "klingon", "auto"])
def test_lookup_unknown(value):
    assert languages.lookup(value) is None


def test_catalog_sorted_by_name_with_tuned():
    cat = languages.catalog({"he"})
    assert [c["name"] for c in cat] == sorted(c["name"] for c in cat)
    he = next(c for c in cat if c["code"] == "he")
    assert he == {"code": "he", "name": "Hebrew", "native": "עברית", "tuned": True}
    assert sum(c["tuned"] for c in cat) == 1


def test_engine_info_languages_follow_prompts(tmp_path, monkeypatch):
    monkeypatch.setenv("LITEECHO_CACHE", str(tmp_path / "cache"))
    info = gather()
    tuned = {c["code"] for c in info["languages"] if c["tuned"]}
    assert tuned == set(load(package_prompts_dir())) & set(languages.LANGUAGES)
    assert {"he", "en"} <= tuned
    assert len(info["languages"]) == 100


def test_prompts_keys_must_be_quoted_strings(tmp_path):
    (tmp_path / "prompts.yml").write_text('"no": "Norsk."\nno: "bool key"\n"en": ""\n"de": "Hallo."\n',
                                          encoding="utf-8")
    assert load(tmp_path) == {"no": "Norsk.", "de": "Hallo."}
    assert load(tmp_path / "missing") == {}


def test_vendored_prompts_parse():
    data = load(package_prompts_dir())
    assert "he" in data and "en" in data
    assert set(data) <= set(languages.LANGUAGES)
