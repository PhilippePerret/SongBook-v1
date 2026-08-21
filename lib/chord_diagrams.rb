require_relative "layout"
require_relative "transpose"

# Résolution des diagrammes d'accords (fichiers SVG sous `assets/chords_diags/`) et
# transposition des blocs `.lyr` (accord + case) — sépare "quel accord/quelle case
# afficher" du dessin lui-même (`Layout`).
module ChordDiagrams
  ASSETS = File.expand_path("../assets/chords_diags", __dir__)

  # `fret` (case) explicite dans la source (ex. "/Bb-6:") → diagramme à CETTE case
  # exactement. Sans lui → case la plus basse disponible ("le plus en haut du manche",
  # Phil, 2026-08-18 — plusieurs cases existeront à terme pour un même accord). Accord ou
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

  def self.diag_path(chord, fret: nil)
    letter = chord[0].upcase
    dir = File.join(ASSETS, letter)
    unless Dir.exist?(dir)
      Layout.conflict!("accord inconnu: #{chord}#{fret ? "-#{fret}" : ""}", solution: "diagramme omis")
      Layout.track_missing_chord(chord)
      return nil
    end

    fc = file_chord(chord)
    entries = Dir.glob(File.join(dir, "#{Regexp.escape(fc)}-*.svg")).filter_map do |f|
      m = File.basename(f).match(/\A#{Regexp.escape(fc)}-(\d+)\.svg\z/)
      [f, m[1].to_i] if m
    end
    entries.select! { |_, kase| kase == fret.to_i } if fret

    if entries.empty?
      Layout.conflict!("accord inconnu ou case absente: #{chord}#{fret ? "-#{fret}" : ""}", solution: "diagramme omis")
      Layout.track_missing_chord(chord)
      return nil
    end

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
  def self.collect_chord_frets(blocks)
    blocks.flat_map { |b| b.lines.flat_map { |l| l.segments.select(&:chord).map { |s| [s.chord, s.fret] } } }.uniq
  end

  # Case transposée pour `chord` (déjà transposé) à partir de la case D'ORIGINE et du
  # décalage en demi-tons — règles posées avec Phil (2026-08-19, voir transpose.rb) :
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
