# frozen_string_literal: true

# Transposition d'accords par INTERVALLE (lettre + altération), pas par simple
# décalage chromatique — impératif : "Bb" transposé ne doit
# jamais devenir son équivalent enharmonique arbitraire (ex. "A#"), il doit garder
# le même écart de LETTRE que l'intervalle de transposition (ex. Am → C#m : Bb
# devient "D", jamais "C##" ni un choix au hasard).
#
# Validé à la main sur deux cas (Am → Cm, Am → C#m), voir tests en bas de
# fichier. Câblé dans `PageBuilder.build` (lecture de `transpose: X → Y` dans les
# `.infos`) et `ChordDiagrams.transpose_blocks!`/`transposed_fret` (gestion de la case).
module Transpose
  LETTRES = %w[A B C D E F G].freeze # ordre alphabétique, PAS l'ordre chromatique
  PITCH_NATUREL = { "A" => 9, "B" => 11, "C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7 }.freeze
  # "d" (dièse, convention interne du projet — noms de fichiers de diags "Fd-*.svg",
  # `Layout.convert_note_symbol`, `DSLParser.normalize_chord`) reconnu ICI au même titre
  # que "#"/"♯" — issue #100 (basse "[Fd]" jamais transposée, ET accords PLEINS "Cdm"/
  # "Fdm" mal transposés, MÊME cause : cette note reconnaissait seulement "#"/"♯"/"b"/"♭").
  DIESE = %w[# ♯ d].freeze
  BEMOL = %w[b ♭].freeze

  NOTE_RE = /\A([A-G])(#|♯|b|♭|d)?\z/

  # "Bb", "F#", "C" -> [lettre, altération en demi-tons (-1/0/1)]. Accepte # et ♯
  # (dièse), b et ♭ (bémol) en entrée — la sortie normalise toujours en ♯/♭
  # (convention d'affichage du projet, voir chord_diagram.rb).
  def self.parse_note(str)
    m = NOTE_RE.match(str) or raise ArgumentError, "note illisible : #{str.inspect}"
    lettre = m[1]
    alteration = if DIESE.include?(m[2]) then 1
                 elsif BEMOL.include?(m[2]) then -1
                 else 0
                 end
    [lettre, alteration]
  end

  def self.pitch(lettre, alteration)
    (PITCH_NATUREL.fetch(lettre) + alteration) % 12
  end

  def self.index_lettre(lettre)
    LETTRES.index(lettre)
  end

  # Décalages (lettres, demi-tons) entre deux notes de départ/arrivée — sert de
  # base à `transpose_note`/`transpose_chord` pour TOUS les accords de la grille,
  # pas seulement la tonique transposée elle-même.
  def self.decalages(depart, arrivee)
    l_depart, a_depart = parse_note(depart)
    l_arrivee, a_arrivee = parse_note(arrivee)
    decalage_lettres = (index_lettre(l_arrivee) - index_lettre(l_depart)) % 7
    decalage_demitons = (pitch(l_arrivee, a_arrivee) - pitch(l_depart, a_depart)) % 12
    [decalage_lettres, decalage_demitons]
  end

  # "Em → Am", "Em -> Am" (fallback ASCII) ou "Em:Am" (`build --transpose`, issue #71)
  # -> [départ, arrivée] tels quels (espaces retirés).
  def self.split_entete(str)
    depart, arrivee = str.split(/→|->|:/).map(&:strip)
    raise ArgumentError, "entête transpose illisible : #{str.inspect}" unless depart && arrivee

    [depart, arrivee]
  end

  # -> [decalage_lettres, decalage_demitons]. Le suffixe de qualité (m, 7, sus...)
  # n'entre PAS dans le calcul de l'intervalle — seule la tonique (lettre+altération)
  # compte.
  def self.parser_entete(str)
    depart, arrivee = split_entete(str)
    # "d(?!im)" (issue #100) : "d" reconnu comme dièse SAUF s'il démarre la qualité
    # "dim" du reste de la chaîne (ex. "Ddim" = RÉ diminué, PAS RÉ# + "im") — même garde
    # que `CHORD_RE` plus bas, brackets `BASS_RE` non concernés (jamais de qualité dedans).
    depart_lettre = depart[/\A[A-G](?:#|♯|b|♭|d(?!im))?/]
    arrivee_lettre = arrivee[/\A[A-G](?:#|♯|b|♭|d(?!im))?/]
    raise ArgumentError, "entête transpose illisible : #{str.inspect}" unless depart_lettre && arrivee_lettre

    decalages(depart_lettre, arrivee_lettre)
  end

  # Transpose UNE note (lettre+altération seule, sans qualité) des décalages donnés.
  # L'altération résultante est calculée pour retomber exactement sur la hauteur
  # cible depuis la NOUVELLE lettre — jamais un choix enharmonique arbitraire.
  def self.transpose_note(str, decalage_lettres, decalage_demitons)
    lettre, alteration = parse_note(str)
    nouvelle_lettre = LETTRES[(index_lettre(lettre) + decalage_lettres) % 7]
    nouvelle_hauteur = (pitch(lettre, alteration) + decalage_demitons) % 12
    nouvelle_alteration = nouvelle_hauteur - PITCH_NATUREL.fetch(nouvelle_lettre)
    # normalise dans [-1, 1] : jamais rencontré au-delà sur les cas réels (accords
    # occidentaux standards), mais sécurité si un double dièse/bémol sortait un jour
    nouvelle_alteration -= 12 if nouvelle_alteration > 6
    nouvelle_alteration += 12 if nouvelle_alteration < -6
    symbole = nouvelle_alteration.positive? ? "♯" : (nouvelle_alteration.negative? ? "♭" : "")
    "#{nouvelle_lettre}#{symbole}"
  end

  # "d(?!im)" (issue #100) : "d" reconnu comme dièse de la FONDAMENTALE d'un accord
  # plein ("Fdm" = FA# mineur), SAUF s'il démarre la qualité "dim" du reste ("Ddim" = RÉ
  # diminué, PAS RÉ# + "im" — bug constaté sur l'asset réel "Fddim[c]-3.svg" = FA#
  # diminué, où le 2e "d" démarre bien "dim", le 1er reste la seule vraie altération).
  CHORD_RE = /\A([A-G](?:#|♯|b|♭|d(?!im))?)(.*)\z/
  # Basse entre crochets ("[Fd]") : ne contient JAMAIS de suffixe de qualité derrière —
  # "d" y est donc SANS AMBIGUÏTÉ un dièse, pas besoin du garde `(?!im)` ci-dessus.
  BASS_RE = /\[([A-G](?:#|♯|b|♭|d)?)\]/

  # Accord complet ("Bb7", "F#m", "C") : sépare tonique et qualité, transpose
  # seulement la tonique, recolle la qualité telle quelle. "F/C" (2 accords de la
  # même mesure, issue DSLParser#parse_line) : chaque accord transposé indépendamment.
  # Basse entre crochets (Manuel/song/chords.adoc) : SEULE ("[C]", pas un accord au sens
  # `CHORD_RE`, juste une note tenue) ou EMBARQUÉE ("Dm7[C]") — transposée elle aussi
  # comme une note à part entière, JAMAIS recopiée telle quelle (bug constaté : "accord
  # illisible : '[C]'", `Transpose::CHORD_RE` exigeait une lettre en tête, ignorait
  # totalement la syntaxe basse entre crochets).
  def self.transpose_chord(str, decalage_lettres, decalage_demitons)
    # "/[B]" (2026-09-07, basse EXPLICITE — voir `DSLParser::BARE_BASS_RE`) : jamais
    # un accord composé au sens "F/C" (`str.include?("/")` ci-dessous) — le "/" ici
    # préfixe UN SEUL token bracket, retiré puis réappliqué après transposition de son
    # contenu (même branche `str.start_with?("[")` que la note aiguë "[B]", inchangée).
    return "/#{transpose_chord(str[1..], decalage_lettres, decalage_demitons)}" if str.start_with?("/[")
    return str.split("/").map { |part| transpose_chord(part, decalage_lettres, decalage_demitons) }.join("/") if str.include?("/")

    transpose_bass = ->(s) { s.gsub(BASS_RE) { "[#{transpose_note($1, decalage_lettres, decalage_demitons)}]" } }
    return transpose_bass.call(str) if str.start_with?("[")

    m = CHORD_RE.match(str) or raise ArgumentError, "accord illisible : #{str.inspect}"
    tonique, qualite = m[1], transpose_bass.call(m[2])
    "#{transpose_note(tonique, decalage_lettres, decalage_demitons)}#{qualite}"
  end

  BASS_NOTE_ITALIAN = { "a" => "la", "b" => "si", "c" => "do", "d" => "ré",
                        "e" => "mi", "f" => "fa", "g" => "sol" }.freeze

  def self.italian_bass_symbol(note)
    syllabe = BASS_NOTE_ITALIAN.fetch(note[0].downcase, note[0].downcase)
    case note[1]
    when "d" then "#{syllabe}♯#{note[2..]}"
    when "b" then "#{syllabe}♭#{note[2..]}"
    else "#{syllabe}#{note[1..]}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  # Tests à la main.
  # sortie normalisée en ♯/♭ (jamais #/b) — les grilles attendues ci-dessous sont
  # écrites en ASCII pour la lisibilité du test, normalisées avant comparaison.
  normaliser = ->(c) { c.tr("#", "♯").tr("b", "♭") }

  grille = %w[Am Eb F# Bb C C#]

  dl, dt = Transpose.parser_entete("Am → Cm")
  resultat = grille.map { |c| Transpose.transpose_chord(c, dl, dt) }
  attendu = %w[Cm Gb A Db Eb E].map(&normaliser)
  puts "Am→Cm : #{resultat.join(' ')} (attendu #{attendu.join(' ')}) #{resultat == attendu ? 'OK' : 'FAIL'}"

  dl, dt = Transpose.parser_entete("Am → C#m")
  resultat = grille.map { |c| Transpose.transpose_chord(c, dl, dt) }
  attendu = %w[C#m G A# D E E#].map(&normaliser)
  puts "Am→C#m : #{resultat.join(' ')} (attendu #{attendu.join(' ')}) #{resultat == attendu ? 'OK' : 'FAIL'}"
end
