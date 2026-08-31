# frozen_string_literal: true

require "tty-prompt"
require_relative "carnet_builder"
require_relative "app_config"
require_relative "file_finder"
require_relative "locale"
require_relative "ansi_colors"

# Résolution interactive d'un titre TAPÉ PAR L'USER (chanson OU carnet) vers un dossier —
# extrait de `CLI` pour être partagé avec `TablatorAssistant` sans require circulaire.
module SongResolver
  extend AnsiColors

  # Chemin direct accepté tel quel, sinon correspondance EXACTE (`find_song_by_title`, sur
  # le nom de dossier ou le `title` de la fiche). Rien d'exact -> Levenshtein
  # (`fuzzy_find_songs`), proposé à l'user pour choix — MÊME 1 SEUL résultat, jamais
  # retenu tel quel sans confirmation.
  def self.resolve_song_folder(name)
    return File.expand_path(name) if name && Dir.exist?(File.expand_path(name))

    songs_dir = AppConfig.songs_dir
    matches = CarnetBuilder.find_song_by_title(songs_dir, name.to_s)
    return matches.first[:folder] if matches.size == 1
    return select_song(nil, matches) if matches.size > 1

    candidates = CarnetBuilder.fuzzy_find_songs(songs_dir, name.to_s)
    abort "chanson introuvable : #{name}" if candidates.empty?

    select_song(Loc.get("song_not_found_did_you_mean"), candidates)
  end

  # Pendant carnet de `resolve_song_folder`.
  def self.resolve_carnet_folder(name)
    return File.expand_path(name) if name && Dir.exist?(File.expand_path(name))

    songbooks_dir = AppConfig.songbooks_dir
    matches = CarnetBuilder.find_carnet_by_title(songbooks_dir, name.to_s)
    return matches.first[:folder] if matches.size == 1
    return select_song(nil, matches) if matches.size > 1

    candidates = CarnetBuilder.fuzzy_find_carnets(songbooks_dir, name.to_s)
    abort "carnet introuvable : #{name}" if candidates.empty?

    select_song(Loc.get("song_not_found_did_you_mean"), candidates)
  end

  def self.select_song(message, songs)
    choices = songs.map { |s| { name: s[:title] ? "#{s[:name]} (#{s[:title]})" : s[:name], value: s[:folder] } }
    choices << { name: Loc.get("none_of_these"), value: nil }
    folder = colored_prompt.select(blue(message.to_s), choices, show_help: false, filter: true)
    abort "aucune correspondance retenue" unless folder

    folder
  end

  # Titre/nom affichable d'un dossier chanson OU carnet déjà résolu (ex. confirmation de
  # `use`) — `title` de la fiche `.infos`/`.inf` si présent, sinon le nom du dossier.
  def self.display_name(folder)
    infos_path = FileFinder.find(folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
    infos["title"] || File.basename(folder)
  end

  # `display_name` + performer entre parenthèses si présent dans le `.infos` (issue #33,
  # confirmation `use song`) — même style que `SongsList.label` ("titre (performer)").
  def self.display_name_with_performer(folder)
    infos_path = FileFinder.find(folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
    title = infos["title"] || File.basename(folder)
    performer = infos["performer"].to_s.strip
    performer.empty? ? title : "#{title} (#{performer})"
  end
end
