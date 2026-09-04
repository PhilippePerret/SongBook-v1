# frozen_string_literal: true

require "tty-prompt"
require_relative "chord_line"
require_relative "chord_diagrams"
require_relative "locale"
require_relative "ansi_colors"
require_relative "transpose"
require_relative "dsl_parser"

# `songbook add chords <chanson>` : pose interactive des accords sur un `.lyr` EXISTANT.
# Entrée = FINIR l'édition (jamais "ligne suivante" — seules les flèches ↑/↓ déplacent
# entre les vers, ←/→ syllabe par syllabe, avec saut de vers en butée). Enregistrement
# TOUJOURS soumis à validation (Entrée comme Ctrl+C), jamais silencieux.
# Pose d'accord : TOUTE lettre démarre `typing` (buffer des caractères tapés tels
# quels), qu'elle corresponde ou non à un raccourci — la décision "accord existant ou
# nouveau" (`typed_match`) se refait à CHAQUE frappe, pas une fois pour toutes ("un
# chiffre est un chiffre" : plus de distinction clavier/pavé numérique, plus de
# correction par INDEX du pavé numérique, un chiffre ÉTEND juste le nom en cours).
# Règle : si `typing` (minuscule initiale) correspond EXACTEMENT à un accord
# déjà connu de cette lettre => affiché/validé comme CET accord existant ; sinon =>
# affiché/validé comme nouvel accord (texte tapé tel quel, capitalisé). MAJUSCULE
# initiale : jamais un raccourci, toujours un nouvel accord, quoi qu'il arrive ensuite.
# Une touche-commande (flèche, X/J/L/T/V/q/Q, Entrée) interrompt/valide la saisie en
# cours avec l'état COURANT (accord existant si ça matchait à cet instant, sinon nouveau
# accord tel que tapé) — Entrée EN PLUS termine la saisie SANS quitter l'éditeur (il en
# faut une 2e pour ça), les autres touches-commandes valident ET s'exécutent dans la
# foulée ("flèche valide aussi l'accord en cours, sans Entrée", généralisé). "n"/"p"/"x"
# minuscules EXCLUES de cette liste (issue #62) : lettres plausibles dans un nom
# d'accord, s'ajoutent simplement à la saisie comme n'importe quel autre caractère.
# `-icanon -echo` (PAS `stty raw` — `raw` coupe aussi ISIG et OPOST : Ctrl+C ne
# signalait plus rien, et `\n` n'effectuait plus de retour chariot, d'où le décalage en
# escalier constaté) : lecture caractère par caractère, ISIG/OPOST intacts, Ctrl+C
# redevient un vrai SIGINT (`Interrupt`, standard Ruby). JAMAIS Échap pour quitter
# (interdiction du projet) — seul Ctrl+C sort.
# Maj+Alt, Maj+Ctrl, Alt+flèche ET Ctrl+flèche abandonnés (diagnostic en direct : le
# terminal les intercepte lui-même pour déplacer son propre curseur, aucun octet
# n'atteint le programme — pas contournable côté code, testé et confirmé) : seul
# Maj+flèche (1 espace) reste côté flèches modifiées. Lettre par lettre : "n"/
# "p" (touches dédiées, jamais interceptées par le terminal), pas de modificateur.
module ChordPlacer
  extend AnsiColors

  ESC = "\e"
  # Pavé numérique en mode application (DECKPAM, `\e=`) : `\eOp`.."\eOy" = touches
  # 0-9 du pavé, distinctes de la ligne du haut du clavier — sans ce mode indiscernables.
  KEYPAD_DIGIT = { "p" => :kp0, "q" => :kp1, "r" => :kp2, "s" => :kp3, "t" => :kp4,
                   "u" => :kp5, "v" => :kp6, "w" => :kp7, "x" => :kp8, "y" => :kp9 }.freeze
  KEYPAD_DIGITS = (1..9).map { |n| :"kp#{n}" }.freeze

  # Rangée du haut d'un clavier AZERTY français SANS Maj = ces symboles, pas les
  # chiffres (confirmé jusqu'au 0 = "à") — un chiffre tapé
  # "normalement" (sans forcer Maj) arrive comme ça en frappe brute. Même table que
  # `TablatorAssistant::AZERTY_DIGITS`.
  AZERTY_DIGITS = { "&" => "1", "é" => "2", "\"" => "3", "'" => "4", "(" => "5",
                     "§" => "6", "è" => "7", "!" => "8", "ç" => "9", "à" => "0" }.freeze

  MODIFIERS = {
    nil => {},
    "2" => { shift: true },
    "3" => { alt: true },
    "4" => { shift: true, alt: true },
    "5" => { ctrl: true },
    "6" => { shift: true, ctrl: true },
    "7" => { alt: true, ctrl: true },
    "8" => { shift: true, alt: true, ctrl: true },
    "9" => { alt: true }, # variante rencontrée sur certains terminaux (Option seul)
  }.freeze

  ARROW = { "A" => :up, "B" => :down, "C" => :right, "D" => :left }.freeze
  WINDOW_SIZE = 4
  # ≤45 signes par ligne.
  HELP_LINES = [
    "x sup acc | X sup tous | A-G Nouvel accord",
    "J/L début/fin vers | T/V début/fin chanson",
    "←/→ ←Syllabe→ | n/p ←Lettre→ |",
    "Enter Sauver | q/^c Annuler",
  ].freeze

  def self.run(lyr_path)
    song_dir = File.dirname(lyr_path)
    raw_lines = File.readlines(lyr_path, chomp: true)
    editable = raw_lines.each_index.select { |i| editable_line?(raw_lines[i]) }
    return if editable.empty?

    chord_lines = editable.to_h { |i| [i, ChordLine.parse(raw_lines[i])] }
    letters = seed_letters(raw_lines)
    load_cached_chords(song_dir).each { |chord| register_chord(letters, chord) }

    # Rationalisation (issue #60) : TOUS les accords de la chanson, pas seulement ceux
    # tapés pendant cette session — un accord chargé tel quel depuis le fichier
    # (`ChordLine.parse` garde la casse d'origine, jamais normalisée) doit ressortir
    # dans la forme correcte à la sauvegarde.
    save = lambda do
      editable.each do |i|
        chord_lines[i].chords.transform_values! do |v|
          ChordLine.split_for_write(v).map { |c| capitalize_chord(c) }.join("/")
        end
        raw_lines[i] = chord_lines[i].serialize
      end
      File.write(lyr_path, "#{raw_lines.join("\n")}\n")
    end

    pos = 0
    cursor = 0
    notice = nil
    # `dirty` d'entrée si des accords CHARGÉS depuis le fichier ne sont pas déjà dans
    # la forme rationalisée (issue #60) — sinon rien ne déclenchait jamais la question
    # de sauvegarde tant qu'aucun autre accord n'était posé/supprimé pendant la
    # session, alors que rationaliser EST le but de la ré-édition.
    dirty = editable.any? do |i|
      chord_lines[i].chords.values.any? do |v|
        ChordLine.split_for_write(v).map { |c| capitalize_chord(c) }.join("/") != v
      end
    end
    # Caractères tapés tels quels (String), `nil` tant qu'aucune saisie n'est en cours
    # (voir en-tête du fichier — décision existant/nouveau refaite à chaque frappe).
    typing = nil

    commit_typing = lambda do
      chord = typed_match(typing, letters, active_letters(letters, chord_lines)) || capitalize_chord(typing)
      register_chord(letters, chord)
      save_cached_chords(song_dir, letters.values.flatten)
      chord_lines[editable[pos]].set_chord(cursor, chord)
      notice = chord_notice(chord, song_dir)
      dirty = true
      typing = nil
    end

    # Touches-commande qui interrompent une saisie en cours ET s'exécutent ensuite
    # normalement (voir en-tête du fichier) — Entrée/Retour arrière traités À PART
    # (Entrée valide SANS s'exécuter comme "quitter", Retour arrière édite le buffer).
    # "n"/"p"/"x" (minuscules) EXCLUES (issue #62) : lettres plausibles DANS un nom
    # d'accord (ex. "Gsus4-3p"), tronquaient la saisie au lieu de s'y ajouter — seules
    # les majuscules (jamais un caractère de nom, toujours minuscule après la 1re
    # lettre) et les autres commandes gardent l'interruption.
    command_key = lambda do |k|
      (k.is_a?(Hash) && k[:arrow]) || (k.is_a?(String) && %w[X J L T V q Q].include?(k))
    end
    # "q"/Ctrl+C : sortie AVEC confirmation par défaut "n" — Entrée (sortie normale, PAS
    # en cours de composition) : confirmation par défaut "y" (cohérent
    # avec `TablatorAssistant`).
    quit_early = false

    begin
      with_raw_terminal do
        loop do
          current = chord_lines[editable[pos]]
          active = active_letters(letters, chord_lines)
          live = typing && (typed_match(typing, letters, active) || typing)
          render_window(editable, chord_lines, pos, cursor, active, notice, live)
          key = read_key

          if typing
            digit = normalize_digit(key)
            if key == :enter
              commit_typing.call
              next
            elsif key == :backspace
              typing = typing.length > 1 ? typing[0..-2] : nil
              next
            elsif command_key.call(key)
              commit_typing.call
              # PAS de `next` : tombe dans le dispatch normal ci-dessous, MÊME touche
              # (`typing` vient d'être remis à `nil`).
            elsif digit
              typing << digit
              next
            elsif key.is_a?(String) && key.length == 1
              typing << key
              next
            else
              next
            end
          end

          case key
          when :enter
            break
          when "q", "Q"
            quit_early = true
            break
          when "x"
            if current.chord_at(cursor)
              current.delete_chord(cursor)
              dirty = true
            end
          when "X"
            if editable.any? { |i| chord_lines[i].chords.any? } && confirm_delete_all
              editable.each { |i| chord_lines[i].chords.clear }
              dirty = true
            end
          when "J"
            cursor = 0
          when "L"
            cursor = current.text.length
          when "n"
            cursor = current.move(cursor, :letter, 1)
          when "p"
            cursor = current.move(cursor, :letter, -1)
          when "T"
            pos = 0
            cursor = 0
          when "V"
            pos = editable.length - 1
            cursor = 0
          when ->(k) { k.is_a?(Hash) && k[:arrow] }
            pos, cursor = apply_arrow(key, pos, cursor, chord_lines, editable)
          else
            # "[" démarre aussi une saisie : basse SEULE, ex. "[fd]"
            # ("basse fa dièse", toujours enregistrée en minuscule, `capitalize_chord`)
            # — même syntaxe crochets que la basse embarquée dans un accord (`A[c]m7`,
            # Manuel/song/chords.adoc), affichée en rendu "/fa♯" (solfège italien,
            # `Layout.display_chord`/`Layout.italian_bass_symbol`).
            typing = key if key.is_a?(String) && key.match?(/\A[a-zA-Z\[]\z/)
          end
        end
      end
    rescue Interrupt
      quit_early = true
    end

    # Terminal déjà restauré ici (ensure de `with_raw_terminal`, qu'on sorte par
    # `break` ou par Ctrl+C). Rien demandé si RIEN n'a changé — sinon TOUJOURS
    # soumis à validation, jamais un enregistrement silencieux.
    save.call if dirty && colored_prompt.yes?(blue(Loc.get("save_changes_question")), default: !quit_early)
  end

  def self.editable_line?(line)
    !line.strip.empty? && !line.strip.match?(/\A\{[^}]*\}\z/)
  end

  # 1re lettre en capitale, TOUJOURS — écrite comme ça, pas juste affichée comme
  # ça. Basse entre crochets (`[fd]` seule, ou embarquée dans un accord "A[c]m7") :
  # même règle (1re lettre capitale, issue #60) — même règle que
  # `DSLParser.normalize_chord`, pas de ré-implémentation, une seule règle partout.
  def self.capitalize_chord(name)
    DSLParser.normalize_chord(name)
  end

  # Étiquette d'un accord dans la légende : raccourci clavier (lettre + éventuel chiffre,
  # voir `register_chord`) = vrai nom d'accord entré, jamais tronqué/réencodé.
  def self.chord_label(letter, index, chord)
    index.zero? ? "#{letter} = #{chord}" : "#{letter}#{index + 1} = #{chord}"
  end

  # Nom RÉEL d'un accord (lettre + altération, ex. "D#", "Bb" — `Transpose::CHORD_RE`,
  # même regex que la transposition, pas de ré-implémentation maison qui risquerait de
  # mal encoder l'altération, ex. "Dd" au lieu de "D#").
  def self.chord_nom(chord)
    Transpose::CHORD_RE.match(chord)&.captures&.first || chord
  end

  # Légende affichée = seulement les accords RÉELLEMENT posés quelque part dans la
  # chanson EN CE MOMENT (bug constaté, la légende gardait tous les
  # accords jamais tapés/mis en cache, même retirés depuis). `letters` complet (avec
  # les accords mis en cache mais plus posés) reste utilisé PARTOUT ailleurs (raccourcis
  # encore disponibles au clavier, `.cached` — voir `save_cached_chords`) : seul
  # l'AFFICHAGE de la légende est filtré ici.
  def self.active_letters(letters, chord_lines)
    # Une valeur "A2-0/A-0" (2 accords collés, voir `ChordLine.parse`) doit compter pour
    # SES DEUX morceaux ici, pas comme un seul accord composé introuvable. `ChordLine.parse`
    # garde la casse TELLE QU'ÉCRITE dans le fichier (jamais normalisée) alors que `letters`
    # (rempli par `seed_letters`) l'est toujours — sans `capitalize_chord` ici, un accord
    # écrit en minuscule dans le `.lyr` ("g2-0C", "/c:", "/d:"...) ne matchait plus rien et
    # disparaissait de la légende (bug constaté, issue #58 : "En Rouge Et Noir").
    used = chord_lines.values.flat_map { |cl| cl.chords.values }
                              .flat_map { |v| ChordLine.split_for_write(v) }
                              .map { |c| capitalize_chord(c) }
                              .uniq
    letters.each_with_object({}) do |(letter, chords), h|
      kept = chords.select { |c| used.include?(c) }
      h[letter] = kept unless kept.empty?
    end
  end

  # 1 ligne (tous les raccourcis) tant que c'est lisible, sinon 1 ligne PAR NOM RÉEL
  # d'accord ("A" différent de "A#", même s'ils partagent le raccourci "a") dès
  # que > 4 noms différents OU > 8 accords différents au total.
  def self.legend_lines(letters)
    entries = letters.flat_map { |l, chords| chords.each_with_index.map { |c, i| [l, i, c] } }
    noms = entries.group_by { |(_l, _i, c)| chord_nom(c) }

    if noms.size > 4 || entries.size > 8
      noms.map { |_nom, group| group.map { |l, i, c| chord_label(l, i, c) }.join("  ") }
    else
      [entries.map { |l, i, c| chord_label(l, i, c) }.join("  ")]
    end
  end

  # Raccourci = 1re lettre du NOM de l'accord ("a" = "A7M", "b" = "Bm9b" — plus
  # confusionnant qu'un ordre a/b/c/d arbitraire). Collision (plusieurs accords partagent
  # la même 1re lettre) : `letters[lettre]` = liste, dans l'ordre de rencontre —
  # désambiguïsée en continuant à taper le nom complet (voir `typed_match`).
  # Une basse SEULE ("[b]"/"[fd]", `ChordDiagrams::BASS_ONLY_RE`) n'est PAS un accord
  # au sens raccourci — jamais indexée sous "[" comme si "[" était une lettre de
  # raccourci valide (bug constaté : "on ne met pas les basses seules
  # en raccourci").
  def self.register_chord(letters, chord)
    return nil if chord.match?(ChordDiagrams::BASS_ONLY_RE)

    letter = chord[0].downcase
    letters[letter] ||= []
    letters[letter] << chord unless letters[letter].include?(chord)
    letter
  end

  # "/" = séparateur d'accords — SAUF le "/" natif du groupe accord
  # de `DSLParser::CHORD_RE` lui-même (ex. "Bb6/C", SANS case sur aucun des deux côtés) :
  # bug constaté par le passé ("il s'agit de deux accords" appliqué à tort ici,
  # "Bb6/C" est UN SEUL accord avec basse) — RESTE un accord unique. En revanche un "/"
  # accidentellement capturé dans le groupe case de `CHORD_RE` (case AVANT le "/", ex.
  # "A2-0/A-0" -> chord="A2" fret="0/A-0", `[^: ]+` trop permissif) est bien DEUX accords
    # distincts, chacun sa propre case ("If You Don't Know Me By Now").
  def self.chord_names(chord, fret)
    chord = capitalize_chord(chord)
    return [fret ? "#{chord}-#{fret}" : chord] unless fret&.include?("/")

    real_fret, *extra = fret.split("/")
    first = real_fret.empty? ? chord : "#{chord}-#{real_fret}"
    [first] + extra.map { |c| capitalize_chord(c) }
  end

  # {lettre => [accords]}, amorcée à partir de TOUS les accords déjà présents dans le
  # fichier (ordre d'apparition).
  def self.seed_letters(lines)
    letters = {}
    seen = []
    lines.each do |raw|
      raw.scan(DSLParser::CHORD_RE) do |m|
        chord_names(m[0], m[1]).each do |chord|
          next if seen.include?(chord)

          seen << chord
          register_chord(letters, chord)
        end
      end
    end
    letters
  end

  # `.cached` (dossier de la chanson) : `chord_list:` — conserve les accords donnés/
  # ajoutés au fil de l'édition MÊME NON UTILISÉS (sinon ils disparaissent
  # simplement, jamais posés nulle part dans le `.lyr` donc jamais retrouvés). Réservé
  # à d'autres infos à l'avenir (root-name fixe ".cached", pas de forme libre).
  def self.cached_path(song_dir)
    File.join(song_dir, ".cached")
  end

  def self.load_cached_chords(song_dir)
    path = cached_path(song_dir)
    return [] unless File.exist?(path)

    line = File.readlines(path).find { |l| l.start_with?("chord_list:") }
    return [] unless line

    line.split(":", 2).last.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def self.save_cached_chords(song_dir, chords)
    path = cached_path(song_dir)
    lines = File.exist?(path) ? File.readlines(path) : []
    new_line = "chord_list: #{chords.join(", ")}\n"
    idx = lines.index { |l| l.start_with?("chord_list:") }
    idx ? (lines[idx] = new_line) : (lines << new_line)
    File.write(path, lines.join)
  end

  # `typing` (buffer tel que tapé) correspond-il à un accord déjà connu ? Nom RÉEL de
  # cet accord si oui, `nil` sinon — MAJUSCULE initiale : jamais de correspondance,
  # toujours `nil` (voir en-tête du fichier).
  def self.typed_match(typing, letters, active)
    return nil if typing[0].match?(/[A-Z]/)

    letter = typing[0].downcase
    bucket = letters[letter]
    return nil unless bucket

    # 1 seule lettre tapée = raccourci immédiat ("b" -> "Bdim" même
    # si "B" seul n'existe pas — bug constaté, le nom tapé devait matcher EXACTEMENT,
    # cassait le raccourci 1 lettre pour tout accord de plus d'1 caractère). Au-delà
    # d'1 caractère, correspondance EXACTE seulement (nécessaire pour "f"+"7" : "F7"
    # existant repris seulement si "F7" lui-même est déjà connu, pas juste "F...").
    return bucket.first if typing.length == 1

    # "b2" = 2e accord de la lettre "b" TEL QU'AFFICHÉ dans la légende (`chord_label`) —
    # index résolu dans le bucket ACTIF (`active_letters`), PAS le bucket complet : un
    # accord en cache mais pas posé est absent de la légende, donc absent de sa
    # numérotation — sinon "e2" affiché pour "E7" tapait en fait un autre accord resté
    # sur "E" (bug constaté : les deux buckets n'étaient pas alignés).
    # Repli sur correspondance EXACTE (bucket complet) si l'index ne pointe rien
    # d'actif (nécessaire pour "f"+"7" : "F7" existant repris seulement si "F7"
    # lui-même est déjà connu, pas juste "F...").
    m = typing.match(/\A[a-z](\d+)\z/)
    if m
      idx = m[1].to_i - 1
      active_bucket = active[letter]
      return active_bucket[idx] if active_bucket && idx >= 0 && idx < active_bucket.size
    end

    candidate = capitalize_chord(typing)
    bucket.include?(candidate) ? candidate : nil
  end

  # Un chiffre est un chiffre : haut du clavier, pavé numérique
  # (`\eOp`..`\eOy`, mode application DECKPAM) ou rangée du haut d'un AZERTY sans Maj
  # (`AZERTY_DIGITS`) — les trois formes normalisées vers le même caractère "0".."9".
  # `nil` si `key` n'est pas un chiffre, sous quelque forme que ce soit.
  def self.normalize_digit(key)
    return key.to_s.delete_prefix("kp") if key.is_a?(Symbol) && (key == :kp0 || KEYPAD_DIGITS.include?(key))
    return AZERTY_DIGITS[key] if key.is_a?(String) && AZERTY_DIGITS.key?(key)
    return key if key.is_a?(String) && key.match?(/\A\d\z/)

    nil
  end

  def self.apply_arrow(key, pos, cursor, chord_lines, editable)
    case key[:arrow]
    when :up then move_vertical(pos, cursor, chord_lines, editable, -1)
    when :down then move_vertical(pos, cursor, chord_lines, editable, 1)
    when :right then move_horizontal(key, pos, cursor, chord_lines, editable, 1)
    when :left then move_horizontal(key, pos, cursor, chord_lines, editable, -1)
    end
  end

  # Pages FIXES (`WINDOW_SIZE`) : ↑/↓ dans la page ne touche qu'au curseur (repositionné
  # dans la limite du texte de la nouvelle ligne), seul le passage à la page suivante
  # ramène le curseur en tête.
  def self.move_vertical(pos, cursor, chord_lines, editable, direction)
    return [pos, cursor] if (direction.negative? && pos.zero?) || (direction.positive? && pos == editable.length - 1)

    page_before = pos / WINDOW_SIZE
    pos += direction
    same_page = pos / WINDOW_SIZE == page_before
    cursor = same_page ? [cursor, chord_lines[editable[pos]].text.length].min : 0
    [pos, cursor]
  end

  # ←/→ nu = syllabe par syllabe, avec saut au vers suivant/précédent en butée (reprend
  # l'ancien rôle de N/P). Shift = décalage des paroles (`shift!`), inchangé. Lettre par
  # lettre : voir "n"/"p" (`run`) — PAS ici, Alt/Ctrl+flèche abandonnés (en-tête du
  # fichier, interceptés par le terminal avant d'atteindre le programme).
  def self.move_horizontal(key, pos, cursor, chord_lines, editable, direction)
    current = chord_lines[editable[pos]]
    mods = key[:mods]
    return [pos, current.shift!(cursor, 1, direction)] if mods[:shift]

    new_cursor = current.move(cursor, :syllable, direction)
    if new_cursor == cursor
      if direction.positive? && pos < editable.length - 1
        pos += 1
        cursor = 0
      elsif direction.negative? && pos.positive?
        pos -= 1
        cursor = chord_lines[editable[pos]].text.length
      end
    else
      cursor = new_cursor
    end
    [pos, cursor]
  end

  # Vérifie l'existence d'un diagramme pour cet accord (dossier de la chanson, puis
  # `assets/chords_diags/` de l'app — les 2 sources demandées) — signalé, discret,
  # jamais négatif : `nil` si trouvé (rien à signaler), sinon un message neutre.
  # "-<case>" (ex. "F7M-1") : même convention que `DSLParser::CHORD_RE`/`.lyr` — accord
  # SIMPLE (pas de "-") => n'importe quelle case (`find_svg` fret nil, la plus basse) ;
  # accord PRÉCIS (avec "-<case>") => CETTE case exacte et AUCUNE AUTRE (bug
  # constaté — cherchait "F7M-1-*.svg" en traitant tout le texte comme un nom
  # opaque, jamais "F7M-1.svg" lui-même, faux "sans diagramme" alors qu'il existait).
  def self.chord_known?(chord, song_dir)
    # Basse seule (`[fd]`) : aucun diagramme dédié n'existe pour ce
    # cas (convention absente de `GenerateChordDiagrams`), le signaler serait donc
    # TOUJOURS un faux négatif — rien à signaler.
    return true if chord.start_with?("[")

    name, fret = chord.split("-", 2)
    fc = ChordDiagrams.file_chord(name)
    return true if ChordDiagrams.find_svg(song_dir, fc, fret, recursive: true)

    !!ChordDiagrams.find_svg(File.join(ChordDiagrams::ASSETS, name[0].upcase), fc, fret, recursive: false)
  end

  def self.chord_notice(chord, song_dir)
    chord_known?(chord, song_dir) ? nil : format(Loc.get("chord_no_diagram"), chord)
  end

  # Pages FIXES de WINDOW_SIZE vers (0-3, 4-7, ...) — jamais de glissement ligne par
  # ligne : ↓ dans la page ne touche qu'au curseur, seul le passage à la page suivante
  # change ce qui est affiché.
  def self.render_window(editable, chord_lines, pos, cursor, letters, notice, typing = nil)
    total = editable.length
    window_start = (pos / WINDOW_SIZE) * WINDOW_SIZE

    print "\e[2J\e[H"
    # Note/séparateur : 2 lignes RÉSERVÉES, toujours (présentes ou vides : les
    # sauts d'écran sont intempestifs). La légende, elle, PEUT changer de nombre de
    # lignes (1 -> plusieurs) en cours d'édition — conséquence assumée du passage en
    # multi-lignes au-delà du seuil, pas un saut accidentel.
    legend_lines(letters).each { |line| puts blue(line) }
    puts gray(notice)
    puts

    window_start.upto([window_start + WINDOW_SIZE, total].min - 1) do |i|
      line = chord_lines[editable[i]]
      render_line(line, i == pos ? cursor : nil, live: i == pos ? typing : nil)
      puts
    end

    HELP_LINES.each { |l| puts gray(l) }
  end

  # Curseur AU-DESSUS des paroles (ligne des accords), jamais sur le texte lui-même —
  # c'est là qu'un accord se pose, sur une syllabe repérée depuis la ligne du dessus.
  # `live` : nom d'accord en cours de saisie au curseur, affiché SANS toucher aux
  # accords réels de la ligne tant que la saisie n'est pas validée.
  def self.render_line(chord_line, cursor, live: nil)
    chords = live && cursor ? chord_line.chords.merge(cursor => live) : chord_line.chords
    width = [chord_line.text.length, cursor.to_i + 1].max
    chords.each { |offset, name| width = [width, offset + name.length].max }
    row = Array.new(width, " ")
    chords.each do |offset, name|
      name.each_char.with_index { |c, k| row[offset + k] = c }
    end
    row[cursor] = "\e[7m#{row[cursor]}\e[0m" if cursor

    puts row.join
    puts chord_line.text
  end

  # "X" (suppression de TOUS les accords de la chanson) : action destructive, jamais
  # sans confirmation. Bascule en mode ligne le temps de la question (même raison que
  # `read_chord_name` : `TTY::Prompt` a besoin d'icanon/echo, pas du mode brut).
  def self.confirm_delete_all
    print "\e>"
    system("stty icanon echo")
    result = colored_prompt.yes?(blue(Loc.get("confirm_delete_all_chords")))
    system("stty -icanon -echo min 1 time 0")
    print "\e="
    result
  end

  def self.with_raw_terminal
    system("stty -icanon -echo min 1 time 0")
    print "\e=" # DECKPAM : distingue le pavé numérique du haut de clavier
    yield
  ensure
    print "\e>"
    system("stty icanon echo")
  end

  # rxvt/anciens terminaux : Shift+flèche en MINUSCULE, SANS paramètre (`\e[a`), pas la
  # forme `\e[1;2A` — accord+d'autres terminaux : les deux formes reconnues.
  LOWERCASE_ARROW = { "a" => :up, "b" => :down, "c" => :right, "d" => :left }.freeze

  def self.read_key
    c1 = $stdin.getc
    return decode_plain(c1) unless c1 == ESC

    c2 = $stdin.getc
    return decode_plain(c1) if c2.nil?

    # macOS Terminal.app (Option comme Meta) : double échap devant la séquence normale —
    # `\e` + `\e[C` pour Alt+Droite, par exemple.
    if c2 == ESC
      c3 = $stdin.getc
      return c2 if c3.nil?
      return with_alt(read_csi) if c3 == "["

      return "\e\e#{c3}"
    end

    if c2 == "["
      read_csi
    elsif c2 == "O"
      c3 = $stdin.getc
      KEYPAD_DIGIT[c3] || "\eO#{c3}"
    else
      "\e#{c2}"
    end
  end

  # Lecture DÉTERMINISTE (pas de "boucle jusqu'à ce que ça matche" — ambigu, pouvait
  # sur-lire des octets appartenant à la touche suivante) : après `\e[`, le caractère
  # suivant dit immédiatement de quelle forme il s'agit.
  def self.read_csi
    c = $stdin.getc
    return { arrow: ARROW[c], mods: {} } if ARROW.key?(c)
    return { arrow: LOWERCASE_ARROW[c], mods: { shift: true } } if LOWERCASE_ARROW.key?(c)
    return "\e[#{c}" unless c == "1"

    rest = +"1"
    rest << $stdin.getc while rest.length < 5 && rest !~ /[ABCD]\z/
    m = rest.match(/\A1;(\d)([ABCD])\z/)
    m ? { arrow: ARROW[m[2]], mods: MODIFIERS.fetch(m[1], {}) } : "\e[#{rest}"
  end

  def self.with_alt(key)
    return key unless key.is_a?(Hash) && key[:arrow]

    key.merge(mods: key[:mods].merge(alt: true))
  end

  # ISIG reste actif (`with_raw_terminal`) : Ctrl+C envoie un vrai SIGINT, Ruby lève
  # `Interrupt` nativement AVANT même d'atteindre ce code dans le cas normal — `\x03`
  # géré ici en secours (terminaux qui ne l'enverraient pas comme signal).
  def self.decode_plain(ch)
    case ch
    when "\x03" then raise Interrupt
    when "\r", "\n" then :enter
    when "\x7F", "\b" then :backspace
    else ch
    end
  end
end
