# frozen_string_literal: true

# Transposition d'accords par INTERVALLE (lettre + altération), pas par simple
# décalage chromatique — impératif pour Phil (2026-08-19) : "Bb" transposé ne doit
# jamais devenir son équivalent enharmonique arbitraire (ex. "A#"), il doit garder
# le même écart de LETTRE que l'intervalle de transposition (ex. Am → C#m : Bb
# devient "D", jamais "C##" ni un choix au hasard).
#
# Validé à la main par Phil sur deux cas (Am → Cm, Am → C#m), voir tests en bas de
# fichier. Câblé dans `PageBuilder.build` (lecture de `transpose: X → Y` dans les
# `.infos`) et `ChordDiagrams.transpose_blocks!`/`transposed_fret` (gestion de la case).
module Transpose
  LETTRES = %w[A B C D E F G].freeze # ordre alphabétique, PAS l'ordre chromatique
  PITCH_NATUREL = { "A" => 9, "B" => 11, "C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7 }.freeze
  DIESE = %w[# ♯].freeze
  BEMOL = %w[b ♭].freeze

  NOTE_RE = /\A([A-G])(#|♯|b|♭)?\z/

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

  # "Em → Am" ou "Em -> Am" (fallback ASCII) -> [decalage_lettres, decalage_demitons].
  # Le suffixe de qualité (m, 7, sus...) n'entre PAS dans le calcul de l'intervalle
  # — seule la tonique (lettre+altération) compte.
  def self.parser_entete(str)
    depart, arrivee = str.split(/→|->/).map(&:strip)
    raise ArgumentError, "entête transpose illisible : #{str.inspect}" unless depart && arrivee

    depart_lettre = depart[/\A[A-G](?:#|♯|b|♭)?/]
    arrivee_lettre = arrivee[/\A[A-G](?:#|♯|b|♭)?/]
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

  CHORD_RE = /\A([A-G](?:#|♯|b|♭)?)(.*)\z/

  # Accord complet ("Bb7", "F#m", "C") : sépare tonique et qualité, transpose
  # seulement la tonique, recolle la qualité telle quelle.
  def self.transpose_chord(str, decalage_lettres, decalage_demitons)
    m = CHORD_RE.match(str) or raise ArgumentError, "accord illisible : #{str.inspect}"
    tonique, qualite = m[1], m[2]
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
  # Tests à la main, validés par Phil (2026-08-19).
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
