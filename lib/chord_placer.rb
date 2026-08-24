# frozen_string_literal: true

require "tty-prompt"
require_relative "chord_line"
require_relative "chord_diagrams"
require_relative "locale"

# `songbook add chords <chanson>` : pose interactive des accords sur un `.lyr` EXISTANT.
# Entrée = FINIR l'édition (jamais "ligne suivante" — seules les flèches ↑/↓ déplacent
# entre les vers). Enregistrement TOUJOURS soumis à validation (Entrée comme Ctrl+C),
# jamais silencieux.
# `-icanon -echo` (PAS `stty raw` — `raw` coupe aussi ISIG et OPOST : Ctrl+C ne
# signalait plus rien, et `\n` n'effectuait plus de retour chariot, d'où le décalage en
# escalier constaté) : lecture caractère par caractère, ISIG/OPOST intacts, Ctrl+C
# redevient un vrai SIGINT (`Interrupt`, standard Ruby). JAMAIS Échap pour quitter
# (interdiction du projet) — seul Ctrl+C sort.
# Maj+Alt et Maj+Ctrl abandonnés (Phil, diagnostic en direct : le terminal les
# intercepte lui-même pour déplacer son propre curseur, aucun octet n'atteint le
# programme — pas contournable côté code) : seul Maj+flèche (1 espace) reste.
module ChordPlacer
  ESC = "\e"
  # Pavé numérique en mode application (DECKPAM, `\e=`) : `\eOp` = touche "0" du pavé,
  # distincte du "0" de la ligne du haut — sans ce mode les deux seraient indiscernables.
  KEYPAD_0_RE = /\AOp\z/

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
  # ≤45 signes par ligne (Phil).
  HELP_LINES = [
    "x: sup | 0: add | N/P: syllabe | A/Z: vers",
    "T/V: chanson | ↑/↓: vers",
    "Entrée/Ctrl+c: finir",
  ].freeze
  HELP_COLOR = "\e[90m"
  ANSI_RESET = "\e[0m"

  def self.run(lyr_path)
    song_dir = File.dirname(lyr_path)
    raw_lines = File.readlines(lyr_path, chomp: true)
    editable = raw_lines.each_index.select { |i| editable_line?(raw_lines[i]) }
    return if editable.empty?

    chord_lines = editable.to_h { |i| [i, ChordLine.parse(raw_lines[i])] }
    letters = seed_letters(raw_lines)
    load_cached_chords(song_dir).each do |chord|
      next if letters.value?(chord)

      letter = next_free_letter(letters)
      letters[letter] = chord if letter
    end
    ask_initial_chords(letters, song_dir) if letters.empty?

    save = lambda do
      editable.each { |i| raw_lines[i] = chord_lines[i].serialize }
      File.write(lyr_path, "#{raw_lines.join("\n")}\n")
    end

    pos = 0
    cursor = 0
    notice = nil
    dirty = false

    begin
      with_raw_terminal do
        loop do
          current = chord_lines[editable[pos]]
          render_window(editable, chord_lines, pos, cursor, letters, notice)
          key = read_key

          case key
          when :enter
            break
          when "x", "X"
            if current.chord_at(cursor)
              current.delete_chord(cursor)
              dirty = true
            end
          when "N"
            new_cursor = current.move(cursor, :syllable, 1)
            if new_cursor == cursor && pos < editable.length - 1
              pos += 1
              cursor = 0
            else
              cursor = new_cursor
            end
          when "P"
            new_cursor = current.move(cursor, :syllable, -1)
            if new_cursor == cursor && pos.positive?
              pos -= 1
              cursor = chord_lines[editable[pos]].text.length
            else
              cursor = new_cursor
            end
          when "A"
            cursor = 0
          when "Z"
            cursor = current.text.length
          when "T"
            pos = 0
            cursor = 0
          when "V"
            pos = editable.length - 1
            cursor = 0
          when :kp0
            name = read_chord_name
            unless name.to_s.strip.empty?
              name = capitalize_chord(name)
              letter = next_free_letter(letters)
              letters[letter] = name if letter
              save_cached_chords(song_dir, letters.values)
              current.set_chord(cursor, name)
              notice = chord_notice(name, song_dir)
              dirty = true
            end
          when ->(k) { k.is_a?(Hash) && k[:arrow] == :up }
            if pos.positive?
              page_before = pos / WINDOW_SIZE
              pos -= 1
              same_page = pos / WINDOW_SIZE == page_before
              cursor = same_page ? [cursor, chord_lines[editable[pos]].text.length].min : 0
            end
          when ->(k) { k.is_a?(Hash) && k[:arrow] == :down }
            if pos < editable.length - 1
              page_before = pos / WINDOW_SIZE
              pos += 1
              same_page = pos / WINDOW_SIZE == page_before
              cursor = same_page ? [cursor, chord_lines[editable[pos]].text.length].min : 0
            end
          else
            before_text = current.text
            new_cursor = handle_movement(current, cursor, key)
            cursor = new_cursor if new_cursor
            dirty = true if current.text != before_text
            if key.is_a?(String) && letters.key?(key)
              current.set_chord(cursor, letters[key])
              dirty = true
            end
          end
        end
      end
    rescue Interrupt
      nil
    end

    # Terminal déjà restauré ici (ensure de `with_raw_terminal`, qu'on sorte par
    # `break` ou par Ctrl+C). Rien demandé si RIEN n'a changé (Phil) — sinon TOUJOURS
    # soumis à validation, jamais un enregistrement silencieux.
    save.call if dirty && TTY::Prompt.new.yes?(Loc.get("save_changes_question"))
  end

  def self.editable_line?(line)
    !line.strip.empty? && !line.strip.match?(/\A\{[^}]*\}\z/)
  end

  # 1re lettre en capitale, TOUJOURS (Phil) — écrite comme ça, pas juste affichée comme ça.
  def self.capitalize_chord(name)
    name[0].upcase + name[1..].to_s
  end

  # Table lettre -> accord, amorcée à partir de TOUS les accords déjà présents dans le
  # fichier (ordre d'apparition).
  def self.seed_letters(lines)
    seen = []
    lines.each do |raw|
      raw.scan(%r{/([^:/\s]+):}) { |m| seen << capitalize_chord(m[0]) unless seen.include?(capitalize_chord(m[0])) }
    end
    ("a".."z").zip(seen).to_h { |letter, chord| [letter, chord] }.compact
  end

  # Demandée AVANT toute édition (hors mode brut : lecture de ligne normale). Skip si
  # rien à ajouter (Entrée seule).
  def self.ask_initial_chords(letters, song_dir)
    print Loc.get("ask_song_chords")
    STDOUT.flush
    input = $stdin.gets.to_s.strip
    input.split(/[\s,]+/).each do |raw_chord|
      next if raw_chord.empty?

      chord = capitalize_chord(raw_chord)
      next if letters.value?(chord)

      letter = next_free_letter(letters)
      letters[letter] = chord if letter
      notice = chord_notice(chord, song_dir)
      puts notice if notice
    end
    save_cached_chords(song_dir, letters.values) unless letters.empty?
  end

  # `.cached` (dossier de la chanson) : `chord_list:` — conserve les accords donnés/
  # ajoutés au fil de l'édition MÊME NON UTILISÉS (Phil : sinon ils disparaissent
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

  def self.handle_movement(chord_line, cursor, key)
    return nil unless key.is_a?(Hash) && key[:arrow]

    direction = key[:arrow] == :right ? 1 : (key[:arrow] == :left ? -1 : nil)
    return nil unless direction

    mods = key[:mods]
    if mods[:shift]
      chord_line.shift!(cursor, 1, direction)
    else
      granularity = mods[:alt] ? :syllable : :letter
      chord_line.move(cursor, granularity, direction)
    end
  end

  # N/P/A/Z/T/V (majuscules) ne partagent plus l'alphabet des accords (minuscules) —
  # seul "x" (suppression) reste dans le même espace, à réserver.
  RESERVED_LETTERS = %w[x].freeze

  def self.next_free_letter(letters)
    ("a".."z").find { |l| !letters.key?(l) && !RESERVED_LETTERS.include?(l) }
  end

  # Vérifie l'existence d'un diagramme pour cet accord (dossier de la chanson, puis
  # `assets/chords_diags/` de l'app — les 2 sources demandées) — signalé, discret,
  # jamais négatif : `nil` si trouvé (rien à signaler), sinon un message neutre.
  def self.chord_known?(chord, song_dir)
    fc = ChordDiagrams.file_chord(chord)
    return true if ChordDiagrams.find_svg(song_dir, fc, nil, recursive: true)

    !!ChordDiagrams.find_svg(File.join(ChordDiagrams::ASSETS, chord[0].upcase), fc, nil, recursive: false)
  end

  def self.chord_notice(chord, song_dir)
    chord_known?(chord, song_dir) ? nil : format(Loc.get("chord_no_diagram"), chord)
  end

  # Pages FIXES de WINDOW_SIZE vers (0-3, 4-7, ...) — jamais de glissement ligne par
  # ligne : ↓ dans la page ne touche qu'au curseur, seul le passage à la page suivante
  # change ce qui est affiché (Phil).
  def self.render_window(editable, chord_lines, pos, cursor, letters, notice)
    total = editable.length
    window_start = (pos / WINDOW_SIZE) * WINDOW_SIZE

    print "\e[2J\e[H"
    # 3 lignes RÉSERVÉES ici, toujours (légende + note discrète + séparateur), présentes
    # ou vides — jamais un nombre de lignes qui varie d'un rafraîchissement à l'autre
    # (Phil : les sauts d'écran sont intempestifs).
    legend = letters.map { |l, c| "#{l} = #{c}" }.join("  ")
    puts legend
    puts "#{HELP_COLOR}#{notice}#{ANSI_RESET}"
    puts

    window_start.upto([window_start + WINDOW_SIZE, total].min - 1) do |i|
      line = chord_lines[editable[i]]
      render_line(line, i == pos ? cursor : nil)
      puts
    end

    HELP_LINES.each { |l| puts "#{HELP_COLOR}#{l}#{ANSI_RESET}" }
  end

  # Curseur AU-DESSUS des paroles (ligne des accords), jamais sur le texte lui-même —
  # c'est là qu'un accord se pose, sur une syllabe repérée depuis la ligne du dessus.
  def self.render_line(chord_line, cursor)
    width = [chord_line.text.length, cursor.to_i + 1].max
    chord_line.chords.each { |offset, name| width = [width, offset + name.length].max }
    row = Array.new(width, " ")
    chord_line.chords.each do |offset, name|
      name.each_char.with_index { |c, k| row[offset + k] = c }
    end
    row[cursor] = "\e[7m#{row[cursor]}\e[0m" if cursor

    puts row.join
    puts chord_line.text
  end

  # Bascule en mode ligne le temps de la saisie (`-icanon -echo` rendait la frappe
  # invisible et cassait `gets` — bug constaté, "l'entrée de l'accord ne fait rien").
  def self.read_chord_name
    system("stty icanon echo")
    print "\r\nAccord : "
    STDOUT.flush
    line = $stdin.gets
    system("stty -icanon -echo min 1 time 0")
    line&.strip
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
      "O#{c3}" =~ KEYPAD_0_RE ? :kp0 : "\eO#{c3}"
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
