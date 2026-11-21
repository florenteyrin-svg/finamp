#!/usr/bin/env python3
"""
Correction des TAGS d'une bibliotheque FLAC pour Jellyfin, en 3 temps :

  1. apercu    : calcule les corrections et les ecrit dans un plan (plan.csv). NE MODIFIE RIEN.
  2. appliquer : applique le plan (seulement les lignes restees dans plan.csv), apres avoir sauvegarde
                 les tags d'origine de chaque fichier modifie.
  3. annuler   : remet les tags d'origine a partir de la sauvegarde.

Seuls les tags (Vorbis comments) sont modifies : le son n'est jamais touche, aucun fichier n'est
deplace, renomme ou supprime. Necessite la bibliotheque "mutagen" (installee, ou le fichier
mutagen-1.47.0-py3-none-any.whl place a cote de ce script).

Exemples :
  python3 corriger_flac.py apercu "/media/Stockage/Mes Musiques/Mes FLAC"
  python3 corriger_flac.py appliquer /DATA/corrections-flac-AAAAMMJJ-HHMM/plan.csv
  python3 corriger_flac.py annuler  /DATA/corrections-flac-AAAAMMJJ-HHMM/sauvegarde-....jsonl
"""
import argparse
import csv
import datetime
import glob
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
try:
    from mutagen.flac import FLAC
except ImportError:
    wheels = sorted(glob.glob(os.path.join(HERE, "mutagen-*.whl")))
    if not wheels:
        sys.exit("mutagen introuvable : place mutagen-1.47.0-py3-none-any.whl a cote de ce script.")
    sys.path.insert(0, wheels[-1])
    from mutagen.flac import FLAC

SEP = " || "  # separates several values of one tag in plan.csv
ABSENT = "(absent)"
DISC_DIR = re.compile(r"^[\(\[]?\s*(cd|disc|disk|disque)[\s._-]*0*(\d+)", re.IGNORECASE)
FEAT_PAREN = re.compile(r"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+)[\)\]]", re.IGNORECASE)
FEAT_SPLIT = re.compile(r"\s+(?:feat\.?|ft\.?|featuring)\s+", re.IGNORECASE)
COMMA_SPLIT = re.compile(r"\s*[,;]\s*")
ARTICLES = {"the", "les", "la", "le"}
DEFAULT_EXCEPTIONS = [
    "Earth, Wind & Fire", "Tyler, The Creator", "Crosby, Stills, Nash & Young", "Crosby, Stills & Nash",
    "Emerson, Lake & Palmer", "Peter, Paul and Mary", "Blood, Sweat & Tears", "Now, Now",
    "Ladysmith Black Mambazo, Inc.", "Bob Marley, The Wailers",
]
RULES = {
    "espaces": "espaces en trop (doubles, debut/fin)",
    "artistes_separes": "plusieurs artistes dans une valeur (virgule, point-virgule, feat.) -> un tag par artiste",
    "orthographe": "meme artiste ecrit differemment -> ecriture la plus frequente",
    "albumartist": "ALBUMARTIST absent ou incoherent dans l'album",
    "album": "nom d'album different dans un meme dossier -> nom majoritaire",
    "disque": "DISCNUMBER absent dans un dossier CD/Disc",
    "manquant": "TITLE / ARTIST / TRACKNUMBER absent -> deduit du nom de fichier ou du dossier",
}


def norm(text):
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", text).strip().casefold()


def clean(text):
    return re.sub(r"\s+", " ", text or "").strip()


def load_exceptions(path):
    names = list(DEFAULT_EXCEPTIONS)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            names += [line.strip() for line in f if line.strip() and not line.startswith("#")]
    return names


def load_spellings(path):
    """orthographes.txt: 'Nom' forces that writing for all its variants; 'Variante => Nom' merges two names."""
    forced, aliases = {}, {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=>" in line:
                    alias, target = (clean(x) for x in line.split("=>", 1))
                    aliases[norm(alias)] = target
                    forced[norm(target)] = target
                else:
                    forced[norm(line)] = clean(line)
    return forced, aliases


def split_artists(value, exceptions):
    """'A, B feat. C' -> ['A', 'B', 'C'], keeping names listed in exceptions whole."""
    text = clean(value)
    protected = {}
    for i, name in enumerate(exceptions):
        pattern = re.compile(re.escape(name), re.IGNORECASE)
        if pattern.search(text):
            token = f"\x00{i}\x00"
            protected[token] = pattern.search(text).group(0)
            text = pattern.sub(token, text)
    featured = FEAT_PAREN.findall(text)
    text = FEAT_PAREN.sub("", text)
    parts = []
    for chunk in FEAT_SPLIT.split(text) + featured:
        parts += COMMA_SPLIT.split(chunk)
    out = []
    for part in parts:
        for token, original in protected.items():
            part = part.replace(token, original)
        part = clean(part)
        if norm(part) in ARTICLES and out:
            # "Roots, The" is one name written backwards: "The Roots"
            out[-1] = f"{part[:1].upper()}{part[1:]} {out[-1]}"
            continue
        if part and norm(part) not in {norm(p) for p in out}:
            out.append(part)
    return out or [clean(value)]


def read(path):
    audio = FLAC(path)
    tags = defaultdict(list)
    for key, value in (audio.tags or []):
        tags[key.upper()].append(value)
    return tags


def fmt(values):
    return ABSENT if not values else SEP.join(values)


def parse(text):
    return [] if text == ABSENT else text.split(SEP)


def first_number(text):
    m = re.match(r"\s*(\d+)", text or "")
    return m.group(1) if m else ""


def from_filename(name):
    """'(3) [2 Unlimited] Tribal Dance.flac' / '03 - Tribal Dance.flac' -> (number, artist, title)."""
    base = os.path.splitext(name)[0]
    number = ""
    m = re.match(r"^\s*[\(\[]?(\d{1,3})[\)\]]?\s*[-._)]?\s*", base)
    if m:
        number, base = m.group(1), base[m.end():]
    artist = ""
    m = re.match(r"^\[([^\]]*)\]\s*", base)
    if m:
        artist, base = m.group(1).strip(), base[m.end():]
    return number.lstrip("0") or number, artist, clean(base)


# ------------------------------------------------------------------------------------------------- apercu

def apercu(args):
    root = os.path.abspath(args.racine)
    out = args.sortie or os.path.expanduser(datetime.datetime.now().strftime("~/corrections-flac-%Y%m%d-%H%M"))
    if os.path.abspath(out).startswith(root + os.sep):
        sys.exit("Le dossier du plan ne doit pas etre dans la bibliotheque.")
    os.makedirs(out, exist_ok=True)
    exceptions = load_exceptions(args.exceptions or os.path.join(HERE, "exceptions_artistes.txt"))

    files = {}
    errors = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if name.lower().endswith(".flac"):
                path = os.path.join(dirpath, name)
                try:
                    files[path] = read(path)
                except Exception as e:  # noqa: BLE001
                    errors.append((path, str(e)))
                if len(files) % 2000 == 0 and files:
                    print(f"  {len(files)} fichiers lus...", file=sys.stderr)

    new = {p: {k: list(v) for k, v in t.items()} for p, t in files.items()}
    reasons = defaultdict(dict)  # path -> tag -> set of rules

    def change(path, tag, values, rule):
        values = [v for v in values if v != ""]
        if values != new[path].get(tag, []):
            new[path][tag] = values
            reasons[path].setdefault(tag, set()).add(rule)

    # 1. whitespace
    for path, tags in new.items():
        for tag in ("ARTIST", "ALBUMARTIST", "ALBUM", "TITLE"):
            if tags.get(tag):
                change(path, tag, [clean(v) for v in tags[tag]], "espaces")

    # 2. several artists in one value
    for path, tags in new.items():
        for tag in ("ARTIST", "ALBUMARTIST"):
            if tags.get(tag):
                split = []
                for value in tags[tag]:
                    for part in split_artists(value, exceptions):
                        if norm(part) not in {norm(s) for s in split}:
                            split.append(part)
                change(path, tag, split, "artistes_separes")

    # 3. spellings: most frequent writing of each artist
    counts = defaultdict(Counter)
    for tags in new.values():
        for tag in ("ARTIST", "ALBUMARTIST"):
            for value in tags.get(tag, []):
                counts[norm(value)][value] += 1
    forced, aliases = load_spellings(args.orthographes or os.path.join(HERE, "orthographes.txt"))
    for alias, target in aliases.items():
        # "Kat De Luna => Kat DeLuna": both spellings end up in one group
        if alias in counts:
            counts[norm(target)].update(counts.pop(alias))
    canonical = {}
    spelling_groups = []
    for key, spellings in counts.items():
        if len(spellings) > 1 or key in forced:
            best = forced.get(key) or max(spellings.items(),
                                          key=lambda kv: (kv[1], kv[0] != kv[0].lower(), kv[0] != kv[0].upper()))[0]
            canonical[key] = best
            if len(spellings) > 1 or best not in spellings:
                spelling_groups.append((best, spellings))
    for alias, target in aliases.items():
        canonical[alias] = canonical.get(norm(target), target)
    for path, tags in new.items():
        for tag in ("ARTIST", "ALBUMARTIST"):
            if tags.get(tag):
                change(path, tag, [canonical.get(norm(v), v) for v in tags[tag]], "orthographe")

    # 4. per album folder: ALBUMARTIST, ALBUM, DISCNUMBER, missing tags
    by_folder = defaultdict(list)
    for path in new:
        by_folder[os.path.dirname(path)].append(path)
    undecided = []
    for folder, paths in sorted(by_folder.items()):
        n = len(paths)
        # ALBUMARTIST
        existing = Counter(norm(new[p]["ALBUMARTIST"][0]) for p in paths if new[p].get("ALBUMARTIST"))
        spelled = {norm(new[p]["ALBUMARTIST"][0]): new[p]["ALBUMARTIST"] for p in paths if new[p].get("ALBUMARTIST")}
        target = None
        if existing:
            key, count = existing.most_common(1)[0]
            if count * 2 >= sum(existing.values()):
                target = spelled[key]
        else:
            main = Counter(norm(new[p]["ARTIST"][0]) for p in paths if new[p].get("ARTIST"))
            names = {norm(new[p]["ARTIST"][0]): new[p]["ARTIST"][0] for p in paths if new[p].get("ARTIST")}
            if main:
                key, count = main.most_common(1)[0]
                if count >= 0.6 * n:
                    target = [names[key]]
                elif len(main) >= 3:
                    target = ["Various Artists"]
                else:
                    undecided.append((os.path.relpath(folder, root), " | ".join(names.values())))
        if target:
            for p in paths:
                change(p, "ALBUMARTIST", target, "albumartist")
        # ALBUM
        albums = Counter(norm(new[p]["ALBUM"][0]) for p in paths if new[p].get("ALBUM"))
        if len({new[p]["ALBUM"][0] for p in paths if new[p].get("ALBUM")}) > 1:
            key, count = albums.most_common(1)[0]
            if count * 2 >= n:
                spelling = Counter(new[p]["ALBUM"][0] for p in paths
                                   if new[p].get("ALBUM") and norm(new[p]["ALBUM"][0]) == key).most_common(1)[0][0]
                for p in paths:
                    if new[p].get("ALBUM"):
                        change(p, "ALBUM", [spelling], "album")
        # DISCNUMBER from a CD/Disc folder name
        m = DISC_DIR.match(os.path.basename(folder))
        if m:
            for p in paths:
                if not new[p].get("DISCNUMBER"):
                    change(p, "DISCNUMBER", [m.group(2).lstrip("0") or "0"], "disque")
        # missing TITLE / TRACKNUMBER / ARTIST
        folder_artist = clean(re.split(r"\s+-\s+", os.path.basename(folder))[0])
        for p in paths:
            number, artist, title = from_filename(os.path.basename(p))
            if not new[p].get("TITLE") and title:
                change(p, "TITLE", [title], "manquant")
            if not new[p].get("TRACKNUMBER") and number:
                change(p, "TRACKNUMBER", [number], "manquant")
            if not new[p].get("ARTIST"):
                guess = artist or (new[p].get("ALBUMARTIST") or [""])[0] or folder_artist
                if guess and not DISC_DIR.match(guess):
                    change(p, "ARTIST", [canonical.get(norm(guess), guess)], "manquant")

    # write the plan
    rows = []
    for path in sorted(reasons):
        for tag in sorted(reasons[path]):
            before, after = files[path].get(tag, []), new[path].get(tag, [])
            if before != after:
                rule = ", ".join(sorted(reasons[path][tag], key=list(RULES).index))
                rows.append([os.path.relpath(path, root), tag, fmt(before), fmt(after), rule])
    plan = os.path.join(out, "plan.csv")
    with open(plan, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f, delimiter=";")
        writer.writerow([f"#racine={root}", "tag", "avant", "apres", "regle"])
        writer.writerows(rows)

    by_rule = Counter()
    for row in rows:
        for rule in row[4].split(", "):
            by_rule[rule] += 1
    lines = [f"Apercu des corrections (RIEN n'a ete modifie) - {datetime.datetime.now():%d/%m/%Y %H:%M}",
             f"Bibliotheque : {root}",
             f"Fichiers lus : {len(files)}   Fichiers a modifier : {len(reasons)}   Changements : {len(rows)}"
             f"   Illisibles : {len(errors)}", ""]
    for rule, label in RULES.items():
        sample = [r for r in rows if rule in r[4].split(", ")]
        lines.append(f"[{by_rule[rule]:6d}] {rule} - {label}")
        for r in sample[:12]:
            lines.append(f"           {r[0]}\n               {r[1]} : {r[2]}  ->  {r[3]}")
        lines.append("")
    lines.append(f"===== ORTHOGRAPHES ({len(spelling_groups)} artistes) : variantes -> ecriture retenue =====")
    for best, spellings in sorted(spelling_groups, key=lambda g: norm(g[0])):
        lines.append(f"  {best:40s} <- " + " | ".join(f"{s} ({n})" for s, n in spellings.most_common()))
    if undecided:
        lines += ["", "===== ALBUMARTIST NON DECIDE (2 artistes a egalite, a regler a la main) ====="]
        lines += [f"  {f}  ->  {a}" for f, a in undecided]
    if errors:
        lines += ["", "===== ILLISIBLES ====="] + [f"  {os.path.relpath(p, root)} : {e}" for p, e in errors]
    lines += ["", f"Plan complet (ouvrable dans un tableur, separateur ';') : {plan}",
              "Pour NE PAS appliquer une correction : supprime sa ligne dans plan.csv avant 'appliquer'.",
              "Pour garder un nom avec une virgule entier : ajoute-le dans exceptions_artistes.txt (a cote du"
              " script) puis relance 'apercu'.",
              "Pour imposer une ecriture : ajoute-la dans orthographes.txt (a cote du script) puis relance 'apercu'."]
    report = "\n".join(lines)
    with open(os.path.join(out, "RESUME-corrections.txt"), "w", encoding="utf-8") as f:
        f.write(report + "\n")
    print(report)


# ---------------------------------------------------------------------------------------------- appliquer

def appliquer(args):
    plan = os.path.abspath(args.plan)
    with open(plan, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f, delimiter=";")
        header = next(reader)
        root = header[0].split("=", 1)[1]
        rows = [r for r in reader if len(r) >= 4]
    by_file = defaultdict(list)
    for rel, tag, before, after, *_ in rows:
        by_file[rel].append((tag, parse(before), parse(after)))
    print(f"Plan : {plan}\nBibliotheque : {root}\n{len(rows)} changements sur {len(by_file)} fichiers.")
    if not args.oui:
        answer = input("Taper OUI (en majuscules) pour appliquer : ")
        if answer.strip() != "OUI":
            sys.exit("Annule, rien n'a ete modifie.")

    backup = os.path.join(os.path.dirname(plan),
                          datetime.datetime.now().strftime("sauvegarde-%Y%m%d-%H%M%S.jsonl"))
    done, skipped = 0, []
    with open(backup, "w", encoding="utf-8") as log:
        log.write(json.dumps({"racine": root}) + "\n")
        for index, (rel, changes) in enumerate(sorted(by_file.items()), 1):
            path = os.path.join(root, rel)
            try:
                audio = FLAC(path)
                if audio.tags is None:
                    audio.add_tags()
                current = {}
                for key, value in audio.tags:
                    current.setdefault(key.upper(), []).append(value)
                mismatch = [t for t, before, _ in changes if current.get(t, []) != before]
                if mismatch:
                    skipped.append((rel, "tags changes depuis l'apercu : " + ", ".join(mismatch)))
                    continue
                original = {t: current.get(t, []) for t, _, _ in changes}
                log.write(json.dumps({"fichier": rel, "avant": original}, ensure_ascii=False) + "\n")
                log.flush()
                os.fsync(log.fileno())
                for tag, _, after in changes:
                    for key in [k for k in audio.tags.keys() if k.upper() == tag]:
                        del audio.tags[key]
                    if after:
                        audio.tags[tag] = after
                audio.save()
                done += 1
            except Exception as e:  # noqa: BLE001
                skipped.append((rel, str(e)))
            if index % 500 == 0:
                print(f"  {index}/{len(by_file)}...")
    print(f"\nTermine : {done} fichiers modifies, {len(skipped)} ignores.")
    for rel, why in skipped[:50]:
        print(f"  ignore : {rel} ({why})")
    print(f"\nSauvegarde des tags d'origine : {backup}\n"
          f"Pour tout remettre comme avant : python3 {os.path.basename(__file__)} annuler \"{backup}\"\n"
          "Dans Jellyfin : Tableau de bord > Mediatheques > Analyser toutes les mediatheques.")


# ------------------------------------------------------------------------------------------------ annuler

def annuler(args):
    with open(args.sauvegarde, encoding="utf-8") as f:
        root = json.loads(f.readline())["racine"]
        entries = [json.loads(line) for line in f if line.strip()]
    print(f"Sauvegarde : {args.sauvegarde}\n{len(entries)} fichiers a remettre comme avant.")
    if not args.oui and input("Taper OUI (en majuscules) pour restaurer : ").strip() != "OUI":
        sys.exit("Annule, rien n'a ete modifie.")
    restored, failed = 0, []
    for entry in entries:
        path = os.path.join(root, entry["fichier"])
        try:
            audio = FLAC(path)
            if audio.tags is None:
                audio.add_tags()
            for tag, values in entry["avant"].items():
                for key in [k for k in audio.tags.keys() if k.upper() == tag]:
                    del audio.tags[key]
                if values:
                    audio.tags[tag] = values
            audio.save()
            restored += 1
        except Exception as e:  # noqa: BLE001
            failed.append((entry["fichier"], str(e)))
    print(f"Restaure : {restored} fichiers. Echecs : {len(failed)}")
    for rel, why in failed[:50]:
        print(f"  {rel} : {why}")


def main():
    parser = argparse.ArgumentParser(description="Correction des tags FLAC en 3 temps (apercu / appliquer / annuler)")
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("apercu", help="calcule le plan, ne modifie rien")
    p.add_argument("racine")
    p.add_argument("--sortie")
    p.add_argument("--exceptions", help="fichier de noms a ne jamais couper (un par ligne)")
    p.add_argument("--orthographes", help="fichier des ecritures imposees (par defaut orthographes.txt a cote du script)")
    p = sub.add_parser("appliquer", help="applique plan.csv (avec sauvegarde)")
    p.add_argument("plan")
    p.add_argument("--oui", action="store_true", help="ne pas demander de confirmation")
    p = sub.add_parser("annuler", help="remet les tags d'origine depuis une sauvegarde")
    p.add_argument("sauvegarde")
    p.add_argument("--oui", action="store_true")
    args = parser.parse_args()
    {"apercu": apercu, "appliquer": appliquer, "annuler": annuler}[args.action](args)


if __name__ == "__main__":
    main()
