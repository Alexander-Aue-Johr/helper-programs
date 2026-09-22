"""Small offline keyword-based title suggestion used by the GUI."""
import json
from collections import Counter
import re

STOP = set(
    """aber alles alle allein also anderen andere anders auch dabei damit danach dann darum dass deine deiner denen denn diese dieser dieses doch durch einfach eigentlich etwas einen einem einer eines genau gerade gerne gewesen glaube haben hatte hätte haben heute hier immer jetzt keine keinen keiner können könnte machen macht meine meinem meiner mich möchte müssen nicht nichts nochmal oder schon sehr seine selbst sich sind sonst sowas später total trotzdem unsere unser unter vielleicht viele vielen vorher waren warum weiter welche wenn werden wirklich wissen würde würden wieder ziemlich zwischen zurück zusammen erst einmal bisschen irgendwie natürlich eigentlich sache sachen leute moment thema frage gesagt sagen fand findet finde geht gibt ganz heißt kommt klar kindern kind menschen beispiel heutzutage dazu deshalb deswegen darauf daran darüber hinaus the this that these those there their they them then than with have been being were would could should about just really because some what when where which your from into does doing don't didn't will well more much very like know think people thing things going said time thank thanks subtitles untertitelung amara vielen dank thank you""".split()
)
STOP.update(
    "richtig gleich musste sollte trotzdem sowas solche diesen diesem einen irgendwie bestimmt wirklich deswegen mittlerweile manchmal irgendwann gemacht reden quasi jemand niemand wusste verstanden versucht allerdings meistens wiederum vorher nachher".split()
)


def suggest_title(out, fallback):
    rows = [json.loads(line) for line in (out / "segments.jsonl").read_text(encoding="utf-8").splitlines()]
    language = json.loads((out / "info.json").read_text(encoding="utf-8")).get("language")
    counts, spelling = Counter(), {}
    for row in rows:
        if row["avg_logprob"] < -0.8 or row["no_speech_prob"] > 0.6 or row["compression_ratio"] > 2.4:
            continue
        for word in re.findall(r"[^\W\d_]{5,}", row["text"], re.UNICODE):
            if language == "de" and not word[0].isupper():
                continue
            key = word.casefold()
            if key not in STOP:
                counts[key] += 1
                spelling.setdefault(key, word)
    words = [spelling[key].capitalize() for key, count in counts.most_common() if count >= 3][:3]
    return " · ".join(words) if words else fallback
