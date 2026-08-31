require_relative "layout"
require_relative "transpose"

# Résolution des diagrammes d'accords (fichiers SVG sous `assets/chords_diags/`) et
# transposition des blocs `.lyr` (accord + case) — sépare "quel accord/quelle case
# afficher" du dessin lui-même (`Layout`).
module ChordDiagrams
  ASSETS = File.expand_path("../assets/chords_diags", __dir__)

  # `fret` (case) explicite dans la source (ex. "/Bb-6:") → diagramme à CETTE case
  # exactement. Sans lui → case la plus basse disponible ("le plus en haut du manche",
  #  — plusieurs cases existeront à terme pour un même accord). Accord ou
  # case introuvable : signalé via `Layout.conflict!` (l'user peut se tromper d'accord),
  # jamais une erreur silencieuse ni un crash.
  # Fichiers SVG nommés en ascii (`Bb7M-1.svg`) — un accord transposé sort en unicode
  # (`Transpose.transpose_chord`, "B♭7M", jamais #/b — voir `transpose.rb`). Sans
  # normalisation ici, un accord transposé ne matchait JAMAIS son diagramme pourtant
  # présent (bug constaté 2026-08-21, "À bicyclette" transposée Em->Am : Bb7/Bb7M/Eb7M
  # signalés manquants alors que leurs SVG existent).
  def self.file_chord(chord)
    chord.tr("♭♯", "b#")
  end

  # Précédence : carnet (`carnet_dir`) fait loi, puis chanson (`song_dir`), puis
  # `assets/chords_diags/` en dernier recours . Recherche RÉCURSIVE
  # dans `carnet_dir`/`song_dir` (SongBook écrit lui-même dans `images/diags/`, mais
  # l'user peut avoir placé un SVG n'importe où dans le dossier).
  # Basse SEULE (ex. "[fd]", tout l'accord entre crochets — Manuel/song/chords.adoc,
  # `chord_placer.rb`) : jamais de diagramme dédié, une seule note tenue, pas un accord
  # signalé "manquant" (bug constaté — le build les listait comme diagrammes
  # absents alors qu'aucun n'existera jamais pour une basse seule).
  BASS_ONLY_RE = /\A\[[^\]]*\]\z/

  def self.diag_path(chord, fret: nil, carnet_dir: nil, song_dir: nil)
    return nil if chord.match?(BASS_ONLY_RE)

    fc = file_chord(chord)

    [carnet_dir, song_dir].compact.each do |dir|
      found = find_svg(dir, fc, fret, recursive: true)
      return found if found
    end

    letter = chord[0].upcase
    found = find_svg(File.join(ASSETS, letter), fc, fret, recursive: false)
    return found if found

    Layout.conflict!("accord inconnu ou case absente: #{chord}#{fret ? "-#{fret}" : ""}", solution: "diagramme omis")
    Layout.track_missing_chord(chord)
    nil
  end

  def self.find_svg(dir, fc, fret, recursive:)
    return nil unless Dir.exist?(dir)

    pattern = File.join(dir, *(recursive ? ["**"] : []), "#{Regexp.escape(fc)}-*.svg")
    entries = Dir.glob(pattern).filter_map do |f|
      m = File.basename(f).match(/\A#{Regexp.escape(fc)}-(\d+)\.svg\z/)
      [f, m[1].to_i] if m
    end
    entries.select! { |_, kase| kase == fret.to_i } if fret
    return nil if entries.empty?

    target_case = fret ? fret.to_i : entries.map { |_, kase| kase }.min
    entries.find { |_, kase| kase == target_case }.first
  end

  # Cases (frets) disponibles pour un accord, triées — sert à `transposed_fret` (jamais
  # une case choisie au hasard, seulement parmi celles qui existent réellement).
  def self.diag_cases(chord)
    letter = chord[0].upcase
    dir = File.join(ASSETS, letter)
    return [] unless Dir.exist?(dir)

    fc = file_chord(chord)
    Dir.glob(File.join(dir, "#{Regexp.escape(fc)}-*.svg")).filter_map do |f|
      m = File.basename(f).match(/\A#{Regexp.escape(fc)}-(\d+)\.svg\z/)
      m[1].to_i if m
    end
  end

  # Paires [chord, fret] uniques (fret nil = pas précisé dans la source). Un même accord
  # avec/sans case explicite, ou à deux cases différentes, compte comme deux entrées —
  # chacune sélectionne un diagramme différent (voir `diag_path`).
  #
  # RÈGLE  : un accord GÉNÉRIQUE (sans "-case") rencontré APRÈS un
  # accord PRÉCIS du même nom hérite de CETTE case — la case la plus basse n'est
  # cherchée que pour un générique rencontré AVANT toute case précise de ce nom. Ex. :
  # "D6" puis "D6-10R" puis "D6" -> le 1er "D6" reste générique (case la plus basse),
  # le 2e "D6" (après "D6-10R") est traité comme "D6-10R" (même diagramme, pas une
  # recherche séparée). Ordre = ordre de PARCOURS de `blocks` (celui déjà utilisé pour
  # le "premier rencontré" du `.uniq` ci-dessous, inchangé).
  # Un accord "/"-composé (ex. "Bb6/C") = DEUX accords DISTINCTS collés en un seul
  # token, faute d'un 2e marqueur `/accord:` dans le format source (Phil, "Blackbird" —
  # PAS un accord+basse : la basse s'écrit TOUJOURS entre crochets, `A[c]m7`/`[cd]`,
  # Manuel/song/chords.adoc — jamais via un "/" direct). Un diagramme PAR accord —
  # cherché tel quel, le nom composé entier ("Bb6/C") ne correspond à AUCUN fichier
  # possible (le "/" romprait le chemin) et était donc TOUJOURS signalé manquant à
  # tort (bug constaté, "Bb6/C", "Bb6/A7", "Am7/G").
  def self.split_chord(chord)
    chord.include?("/") ? chord.split("/") : [chord]
  end

  def self.collect_chord_frets(blocks)
    precise_seen = {}
    pairs = blocks.flat_map { |b| b.lines.flat_map { |l| l.segments.select(&:chord).map { |s| [s.chord, s.fret] } } }
    pairs = pairs.flat_map { |chord, fret| split_chord(chord).map { |c| [c, fret] } }
    pairs.map! do |chord, fret|
      if fret
        precise_seen[chord] = fret
        [chord, fret]
      else
        [chord, precise_seen[chord]]
      end
    end
    pairs.uniq
  end

  # Case transposée pour `chord` (déjà transposé) à partir de la case D'ORIGINE et du
  # décalage en demi-tons — voir transpose.rb) :
  # pas de case au départ -> accord neutre ; case cible < 0 -> accord neutre ; case cible
  # dans [0, 10] et diagramme dispo -> direct ; dans [0, 10] mais diagramme pas encore
  # construit -> signalé, accord neutre en attendant ; case cible > 10 -> diagramme
  # existant le plus haut pour cet accord (jamais une case au hasard).
  def self.transposed_fret(chord, fret, decalage_demitons)
    return nil unless fret

    target = fret.to_i + decalage_demitons
    return nil if target.negative?

    if target <= 10
      return target.to_s if diag_cases(chord).include?(target)

      Layout.conflict!("case transposée #{target} introuvable pour #{chord}", solution: "accord neutre en attendant le diagramme")
      return nil
    end

    diag_cases(chord).max&.to_s
  end

  # Applique la transposition (accord + case) à tous les segments des blocs `.lyr`, en
  # place — appelé avant tout usage des blocs (diags, rendu) pour que le reste du
  # pipeline n'ait jamais à savoir qu'une transposition a eu lieu.
  def self.transpose_blocks!(blocks, decalage_lettres, decalage_demitons)
    blocks.each_value do |block|
      block.lines.each do |line|
        line.segments.each do |seg|
          next unless seg.chord

          new_chord = Transpose.transpose_chord(seg.chord, decalage_lettres, decalage_demitons)
          seg.fret = transposed_fret(new_chord, seg.fret, decalage_demitons)
          seg.chord = new_chord
        end
      end
    end
  end
end
