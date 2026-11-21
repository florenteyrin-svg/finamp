#!/usr/bin/env python3
"""
Analyse (LECTURE SEULE) d'une bibliotheque FLAC pour Jellyfin.

- N'ecrit JAMAIS dans les fichiers de musique : ils sont seulement ouverts en lecture ("rb"),
  et seul le debut de chaque fichier (les tags) est lu.
- Ecrit uniquement un dossier de rapport (par defaut ~/analyse-flac-AAAAMMJJ-HHMM).
- Aucune dependance : Python 3.8+ suffit.

Utilisation :
    python3 analyse_flac.py "/media/Stockage/Mes Musiques/Mes FLAC"
    python3 analyse_flac.py "/media/Stockage/Mes Musiques/Mes FLAC" --zoom "dj abdel"
"""
import argparse
import csv
import datetime
import os
import re
import struct
import sys
import unicodedata
from collections import Counter, defaultdict

DISC_DIR = re.compile(r"^(cd|disc|disk|disque|dvd)[\s._-]*\d+\b", re.IGNORECASE)
VOLUME_DIR = re.compile(r"\b(vol(ume)?|tome|part(ie)?)[\s._-]*\d+", re.IGNORECASE)
MULTI_ARTIST = re.compile(r"\s*(,|;|/|&|\bfeat\.?|\bft\.?|\bfeaturing\b|\bvs\.?)\s*", re.IGNORECASE)
TAG_KEYS = ["ARTIST", "ALBUMARTIST", "ALBUM", "TITLE", "TRACKNUMBER", "DISCNUMBER", "DATE", "GENRE",
            "COMPILATION", "MUSICBRAINZ_ALBUMID"]


def read_tags(path):
    """Vorbis comments of a FLAC file (keys in upper case, each a list of values). Read only."""
    tags = defaultdict(list)
    with open(path, "rb") as f:
        head = f.read(4)
        if head == b"ID3\x03" or head[:3] == b"ID3":
            # ID3 tag in front of the FLAC stream (not standard): skip it
            rest = f.read(6)
            size = (rest[2] << 21) | (rest[3] << 14) | (rest[4] << 7) | rest[5]
            f.seek(10 + size)
            head = f.read(4)
        if head != b"fLaC":
            raise ValueError("pas un FLAC valide")
        while True:
            header = f.read(4)
            if len(header) < 4:
                break
            last = header[0] & 0x80
            block_type = header[0] & 0x7F
            length = int.from_bytes(header[1:4], "big")
            if block_type == 4:
                data = f.read(length)
                pos = 0
                vendor_len = struct.unpack_from("<I", data, pos)[0]
                pos += 4 + vendor_len
                count = struct.unpack_from("<I", data, pos)[0]
                pos += 4
                for _ in range(count):
                    n = struct.unpack_from("<I", data, pos)[0]
                    pos += 4
                    entry = data[pos:pos + n].decode("utf-8", "replace")
                    pos += n
                    if "=" in entry:
                        key, value = entry.split("=", 1)
                        tags[key.strip().upper()].append(value.strip())
                break
            f.seek(length, 1)
            if last:
                break
    return tags


def norm(text):
    """Comparison key: no accents, no case, single spaces."""
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", text).strip().casefold()


def first(tags, key):
    values = tags.get(key) or []
    return values[0] if values else ""


def main():
    parser = argparse.ArgumentParser(description="Analyse en lecture seule d'une bibliotheque FLAC")
    parser.add_argument("racine", help="dossier de la bibliotheque (ex: /media/Stockage/Mes Musiques/Mes FLAC)")
    parser.add_argument("--sortie", help="dossier du rapport (par defaut ~/analyse-flac-DATE)")
    parser.add_argument("--zoom", action="append", default=[],
                        help="detail complet pour un artiste ou un album (ex: --zoom \"dj abdel\"), repetable")
    args = parser.parse_args()

    root = os.path.abspath(args.racine)
    if not os.path.isdir(root):
        sys.exit(f"Dossier introuvable : {root}")
    out = args.sortie or os.path.expanduser(datetime.datetime.now().strftime("~/analyse-flac-%Y%m%d-%H%M"))
    if os.path.abspath(out).startswith(root + os.sep):
        sys.exit("Le dossier du rapport ne doit pas etre dans la bibliotheque.")
    os.makedirs(out, exist_ok=True)

    files = []  # (path, folder, tags)
    unreadable = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.lower().endswith(".flac"):
                continue
            path = os.path.join(dirpath, name)
            try:
                files.append((path, dirpath, read_tags(path)))
            except Exception as e:  # noqa: BLE001
                unreadable.append((path, str(e)))
            if len(files) % 2000 == 0 and files:
                print(f"  {len(files)} fichiers lus...", file=sys.stderr)

    rel = lambda p: os.path.relpath(p, root)  # noqa: E731
    by_folder = defaultdict(list)
    for path, folder, tags in files:
        by_folder[folder].append((path, tags))

    issues = defaultdict(list)  # name -> rows

    # 1. Folders: several albums in one folder, one album over several folders, volume sub-folders
    album_folders = defaultdict(set)
    for folder, items in by_folder.items():
        albums = Counter(first(t, "ALBUM") for _, t in items)
        if len([a for a in albums if a]) > 1:
            issues["dossier_plusieurs_albums"].append(
                [rel(folder), len(items), " | ".join(f"{a or '(vide)'} ({n})" for a, n in albums.most_common())])
        for album in albums:
            if album:
                key = (norm(album), norm(first(items[0][1], "ALBUMARTIST") or first(items[0][1], "ARTIST")))
                album_folders[key].add(folder)
    for (album, artist), folders in album_folders.items():
        parents = {os.path.dirname(f) for f in folders}
        disc_like = all(DISC_DIR.match(os.path.basename(f)) for f in folders)
        if len(folders) > 1 and not (len(parents) == 1 and disc_like):
            issues["album_eclate_sur_plusieurs_dossiers"].append(
                [album, artist, len(folders), " | ".join(sorted(rel(f) for f in folders))])

    children = defaultdict(list)
    for folder in by_folder:
        children[os.path.dirname(folder)].append(folder)
    for parent, subs in children.items():
        if len(subs) < 2:
            continue
        names = [os.path.basename(s) for s in subs]
        not_disc = [n for n in names if not DISC_DIR.match(n)]
        sub_albums = {norm(first(by_folder[s][0][1], "ALBUM")) for s in subs}
        same_album_tag = len(sub_albums) == 1
        if VOLUME_DIR.search(" ".join(names)) or (same_album_tag and not_disc):
            issues["sous_dossiers_volumes_ou_cd_non_reconnus"].append(
                [rel(parent), " | ".join(sorted(names)),
                 "meme tag ALBUM" if same_album_tag else "tags ALBUM differents",
                 "Jellyfin ne reconnait les disques que nommes CD1 / Disc 1 ; deux albums distincts = deux dossiers freres"])

    # 2. Tags
    artist_spellings = defaultdict(Counter)
    for path, folder, tags in files:
        r = rel(path)
        for key in ("TITLE", "ALBUM", "ARTIST", "TRACKNUMBER"):
            if not first(tags, key):
                issues["tag_manquant"].append([r, key])
        if not first(tags, "ALBUMARTIST"):
            issues["albumartist_manquant"].append([r, first(tags, "ARTIST")])
        for key in ("ARTIST", "ALBUMARTIST"):
            for value in tags.get(key, []):
                for part in MULTI_ARTIST.split(value):
                    part = part.strip()
                    if part and not MULTI_ARTIST.fullmatch(part):
                        artist_spellings[norm(part)][part] += 1
                if len(tags.get(key, [])) == 1 and MULTI_ARTIST.search(value):
                    issues["plusieurs_artistes_dans_une_seule_valeur"].append([r, key, value])

    for folder, items in by_folder.items():
        album_artists = {first(t, "ALBUMARTIST") for _, t in items}
        if len(album_artists) > 1:
            issues["albumartist_different_dans_un_meme_album"].append(
                [rel(folder), " | ".join(sorted(a or "(vide)" for a in album_artists))])
        numbers = Counter((first(t, "DISCNUMBER").split("/")[0] or "1", first(t, "TRACKNUMBER").split("/")[0])
                          for _, t in items if first(t, "TRACKNUMBER"))
        dup = [f"disque {d} piste {n} (x{c})" for (d, n), c in numbers.items() if c > 1]
        if dup:
            issues["numeros_de_piste_en_double"].append([rel(folder), " | ".join(sorted(dup))])
        dates = {first(t, "DATE")[:4] for _, t in items}
        if len(dates) > 1:
            issues["annee_differente_dans_un_meme_album"].append([rel(folder), " | ".join(sorted(dates))])

    for key, spellings in artist_spellings.items():
        if len(spellings) > 1:
            issues["meme_artiste_ecrit_differemment"].append(
                [" | ".join(f"{s} ({n})" for s, n in spellings.most_common())])

    # 3. Write the report
    headers = {
        "dossier_plusieurs_albums": ["dossier", "fichiers", "albums (nombre de fichiers)"],
        "album_eclate_sur_plusieurs_dossiers": ["album", "artiste", "dossiers", "liste"],
        "sous_dossiers_volumes_ou_cd_non_reconnus": ["dossier parent", "sous-dossiers", "tags", "remarque"],
        "tag_manquant": ["fichier", "tag"],
        "albumartist_manquant": ["fichier", "ARTIST"],
        "plusieurs_artistes_dans_une_seule_valeur": ["fichier", "tag", "valeur"],
        "albumartist_different_dans_un_meme_album": ["dossier", "valeurs"],
        "numeros_de_piste_en_double": ["dossier", "doublons"],
        "annee_differente_dans_un_meme_album": ["dossier", "annees"],
        "meme_artiste_ecrit_differemment": ["orthographes (nombre)"],
    }
    explanations = {
        "dossier_plusieurs_albums": "Plusieurs albums dans un meme dossier : Jellyfin les fusionne en un seul album.",
        "album_eclate_sur_plusieurs_dossiers": "Un meme album (meme tag) dans plusieurs dossiers : Jellyfin peut en faire plusieurs albums.",
        "sous_dossiers_volumes_ou_cd_non_reconnus": "Sous-dossiers (Vol.1, Vol.2...) dans un dossier d'album : risque de fusion ou de mauvais classement (cas DJ Abdel).",
        "tag_manquant": "Tags de base absents.",
        "albumartist_manquant": "Pas d'ALBUMARTIST : l'album peut ne pas apparaitre sur la page de l'artiste.",
        "plusieurs_artistes_dans_une_seule_valeur": "Plusieurs artistes dans une seule valeur (\"DJ Abdel, Atlantic Star\") : Jellyfin cree un artiste a ce nom entier.",
        "albumartist_different_dans_un_meme_album": "ALBUMARTIST qui change d'un morceau a l'autre dans un meme dossier : l'album peut etre coupe en plusieurs.",
        "numeros_de_piste_en_double": "Deux morceaux avec le meme numero (souvent deux albums ou deux disques melanges).",
        "annee_differente_dans_un_meme_album": "Annee differente selon les morceaux d'un meme dossier.",
        "meme_artiste_ecrit_differemment": "Meme artiste ecrit de plusieurs facons (\"DJ Abdel\" / \"Dj Abdel\") : Jellyfin peut faire plusieurs pages d'artiste.",
    }
    summary = [f"Analyse FLAC (lecture seule) - {datetime.datetime.now():%d/%m/%Y %H:%M}",
               f"Bibliotheque : {root}",
               f"Fichiers FLAC lus : {len(files)}   Dossiers d'album : {len(by_folder)}   Illisibles : {len(unreadable)}",
               ""]
    for name, header in headers.items():
        rows = issues.get(name, [])
        summary.append(f"[{len(rows):6d}] {name} - {explanations[name]}")
        for row in rows[:8]:
            summary.append("           - " + "  ->  ".join(str(c) for c in row)[:300])
        if len(rows) > 8:
            summary.append(f"           ... (liste complete dans {name}.csv)")
        with open(os.path.join(out, f"{name}.csv"), "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f, delimiter=";")
            writer.writerow(header)
            writer.writerows(rows)
    if unreadable:
        with open(os.path.join(out, "illisibles.csv"), "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f, delimiter=";")
            writer.writerow(["fichier", "erreur"])
            writer.writerows([[rel(p), e] for p, e in unreadable])
        summary.append(f"[{len(unreadable):6d}] illisibles - fichiers non lus (voir illisibles.csv)")

    for query in args.zoom:
        q = norm(query)
        summary += ["", f"===== ZOOM : {query} ====="]
        for path, folder, tags in files:
            text = norm(" ".join(first(tags, k) for k in ("ARTIST", "ALBUMARTIST", "ALBUM")) + " " + rel(path))
            if q in text:
                summary.append(rel(path))
                summary.append("    " + "  ".join(f"{k}={'; '.join(tags.get(k, []))}" for k in TAG_KEYS if tags.get(k)))

    report = "\n".join(summary)
    with open(os.path.join(out, "RESUME.txt"), "w", encoding="utf-8") as f:
        f.write(report + "\n")
    print(report)
    print(f"\nRapport complet : {out}")


if __name__ == "__main__":
    main()
