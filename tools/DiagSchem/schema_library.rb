# frozen_string_literal: true

require "fileutils"

# Insertion d'un nouveau schéma dans `assets/chords_diags/<Lettre>/schemas.txt` —
# logique PURE (pas d'I/O caché dans `insert`/`conflict`/`parse_lines`/`sort_key`,
# testable sans fichiers), séparée de l'assistant interactif (`DiagSchem`) et de la
# génération SVG (`ChordDiagram`). Règle d'ordre dictée par  —
# appliquée MÉCANIQUEMENT, jamais en essayant de deviner/respecter une organisation
# plus fine déjà présente dans les fichiers existants :
#   - bémol puis naturel puis dièse
#   - majeur puis mineur
#   - noms du plus court au plus long
#   - chaque "type" (couple altération/qualité) séparé par une ligne vide
module SchemaLibrary
  ASSETS = File.expand_path("../../assets/chords_diags", __dir__)

  ENTRY_RE = /\A(.+)-(\d+)\s*:\s*(.+)\z/

  Entry = Struct.new(:nom, :case_ref, :tokens, :idx)

  def self.chord_letter(nom)
    nom[0].upcase
  end

  def self.schemas_path(nom)
    File.join(ASSETS, chord_letter(nom), "schemas.txt")
  end

  # 2e caractère 'b'/'d' = altération (convention interne, `layout.rb`
  # `convert_note_symbol`) — bémol < naturel < dièse.
  def self.alteration_rank(nom)
    case nom[1]
    when "b" then 0
    when "d" then 2
    else 1
    end
  end

  # 'm' minuscule juste après racine+altération = mineur (distinct du 'M' majuscule de
  # "7M" = majeur 7e) — majeur < mineur.
  def self.quality_rank(nom)
    start = alteration_rank(nom) == 1 ? 1 : 2
    nom[start] == "m" ? 1 : 0
  end

  def self.sort_key(nom, case_ref)
    [alteration_rank(nom), quality_rank(nom), nom.length, nom, case_ref.to_i]
  end

  def self.parse_lines(lines)
    lines.each_with_index.filter_map do |line, idx|
      m = ENTRY_RE.match(line.strip)
      next nil unless m

      Entry.new(m[1], m[2].to_i, m[3].strip, idx)
    end
  end

  # Raison de refus (`:nom` ou `:schema`), `nil` si l'insertion est permise. Vérifie
  # 1) le nom (même nom ET même case) 2) SURTOUT le schéma (mêmes positions, sous
  # n'importe quel autre nom/case — un doublon visuel, plus dangereux qu'un doublon de
  # nom).
  def self.conflict(entries, nom, case_ref, tokens)
    return :nom if entries.any? { |e| e.nom == nom && e.case_ref == case_ref.to_i }
    return :schema if entries.any? { |e| e.tokens == tokens }

    nil
  end

  # Insère `new_line` à sa place (voir `sort_key`) — ne touche à AUCUNE autre ligne du
  # fichier, une ligne vide séparatrice ajoutée seulement si le voisin (avant/après)
  # est d'un type DIFFÉRENT et qu'aucune ligne vide n'y est déjà.
  def self.insert(content, nom, case_ref, tokens)
    lines = content.to_s.each_line.map(&:chomp)
    entries = parse_lines(lines)
    new_line = "#{nom}-#{case_ref} : #{tokens}"
    return "#{new_line}\n" if entries.empty?

    key = sort_key(nom, case_ref)
    after_idx = entries.index { |e| (sort_key(e.nom, e.case_ref) <=> key).positive? }
    after = after_idx ? entries[after_idx] : nil
    prev = after_idx ? (after_idx.zero? ? nil : entries[after_idx - 1]) : entries.last

    same_type = ->(e) { e && alteration_rank(e.nom) == alteration_rank(nom) && quality_rank(e.nom) == quality_rank(nom) }
    # Juste après `prev` (JAMAIS juste avant `after` : sinon une ligne vide déjà
    # présente entre les deux — séparant historiquement d'autres blocs — se retrouve du
    # mauvais côté de l'insertion) — à défaut de `prev`, juste avant `after` ; à défaut
    # des deux, en fin de fichier.
    insert_at = prev ? prev.idx + 1 : (after ? after.idx : lines.size)

    block = []
    block << "" if prev && !same_type.call(prev)
    block << new_line
    block << "" if after && !same_type.call(after) && lines[insert_at] != ""

    lines.insert(insert_at, *block)
    "#{lines.join("\n")}\n"
  end

  # --- I/O (frontière, hors logique pure ci-dessus) ---------------------

  def self.entries(nom)
    path = schemas_path(nom)
    return [] unless File.exist?(path)

    parse_lines(File.read(path).each_line.map(&:chomp))
  end

  # Vérifie et insère en une fois — renvoie `nil` en cas de succès, ou la raison de
  # refus (`:nom`/`:schema`).
  def self.save(nom, case_ref, tokens)
    path = schemas_path(nom)
    content = File.exist?(path) ? File.read(path) : ""
    existing = parse_lines(content.each_line.map(&:chomp))

    reason = conflict(existing, nom, case_ref, tokens)
    return reason if reason

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, insert(content, nom, case_ref, tokens))
    nil
  end
end
