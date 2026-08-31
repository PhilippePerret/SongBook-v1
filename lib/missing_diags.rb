# frozen_string_literal: true

require_relative "layout"
require_relative "chord_diagrams"
require_relative "page_builder"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "app_config"
require_relative "session"
require_relative "../tools/ChordDiagram/generate_chord_diagrams"

# `songbook missing diags` : accords utilisés dans des chansons sans diagramme SVG
# correspondant — scan LÉGER (parsing `.lyr` seul, sans génération de PDF : "si
# l'outil met plus d'une seconde sur toutes les chansons, je le rejetterai").
module MissingDiags
  # Chansons à scanner, selon le contexte (bon sens) : chanson courante
  # -> ses accords seuls ; carnet courant -> toutes ses chansons ; `all: true` -> TOUTE
  # la bibliothèque (`AppConfig.songs_dir`), quel que soit le contexte. `nil` = aucun
  # contexte trouvé (à l'appelant d'`abort`).
  def self.songs_to_scan(all:)
    return CarnetBuilder.all_songs(AppConfig.songs_dir).map { |s| s[:folder] } if all

    return [Session.song] if Session.song
    return songs_of_carnet(Session.carnet) if Session.carnet
    return [Dir.pwd] if CarnetBuilder.song_folder?(Dir.pwd)
    return songs_of_carnet(Dir.pwd) if CarnetBuilder.carnet_folder?(Dir.pwd)

    nil
  end

  def self.songs_of_carnet(carnet_folder)
    tdm_path = FileFinder.find(carnet_folder, :tdm)
    return [] unless tdm_path

    chansons_dir = File.expand_path("../../Chansons", carnet_folder)
    names = File.readlines(tdm_path).map { |l| l.sub(/\A-\s*/, "").strip }.reject(&:empty?)
    CarnetBuilder.resolve_song_folders(chansons_dir, names, false)
      .filter_map { |_, entry| entry && File.join(chansons_dir, entry[:folder]) }
  end

  # Scanne `folders` — jamais de PDF généré, juste `.lyr`/`.infos` lus + résolution
  # `ChordDiagrams.diag_path` (même règle EXACTE que la production réelle : un accord
  # SANS case explicite matche la case la plus petite disponible, `Manuel/_dev/specs/
  # specs.md` § "Résolution d'un accord vers son diagramme"). `sensitivity: "low"`
  # (restaurée après coup) — un simple scan n'écrit RIEN dans `conflicts.log`
  # (`Layout.conflict!`, appelé en interne par `diag_path`), ce fichier reste réservé
  # aux VRAIES productions.
  # Clé du hash renvoyé = accord tel qu'écrit dans le `.lyr` + `-case` SEULEMENT si
  # une case était explicitement demandée  : "Am" introuvable
  # (générique) et "Am-3" introuvable (case précise) sont deux manques DISTINCTS,
  # jamais confondus sous la même étiquette "Am" — sinon la liste ment dès qu'un
  # AUTRE "Am" du même texte, générique, résout bien vers `Am-0.svg`).
  def self.scan(folders)
    # Un schéma peut exister dans `schemas.txt` (assistant `diag`) SANS que son SVG
    # ait jamais été produit — dans ce cas, "manquant" est FAUX : il faut d'abord
    # construire tous les diags d'application en attente , "B-7").
    GenerateChordDiagrams.run

    previous_sensitivity = Layout.sensitivity
    Layout.sensitivity = "low"
    missing = Hash.new { |h, k| h[k] = [] }
    folders.each do |folder|
      infos_path = FileFinder.find(folder, :inf)
      meta = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
      title = meta["title"] || File.basename(folder)
      PageBuilder.chord_frets_for_song(folder).each do |chord, fret|
        raw = fret ? "#{chord}-#{fret}" : chord
        # "/" = diviseur d'accord, uniquement ici pour `missing diags` (Phil,
        # 2026-08-30) — "Am9-5/Am" = accord "Am9-5" ET accord "Am", chacun vérifié
        # séparément. Ne touche PAS `ChordDiagrams.collect_chord_frets` (code partagé
        # avec la production réelle).
        raw.split("/").each do |token|
          c, f = token.include?("-") ? token.split("-", 2) : [token, nil]
          next if ChordDiagrams.diag_path(c, fret: f, song_dir: folder)

          missing[token] << title unless missing[token].include?(title)
        end
      end
    end
    missing
  ensure
    Layout.sensitivity = previous_sensitivity
  end
end
