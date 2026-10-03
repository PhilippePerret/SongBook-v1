# frozen_string_literal: true

require "yaml"
require_relative "ansi_colors"
require_relative "app_config"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "locale"
require_relative "session"
require_relative "song_resolver"
require_relative "songbook_site"

# `songbook add-to [carnet]` : ajoute une chanson (courante, sinon choisie) à la table
# des matières d'un carnet (désigné, courant, sinon choisi), dans l'ordre alphabétique
# des ids — ou, sur demande, `ie add-to` complet (site des éditions).
module SongAdder
  extend AnsiColors

  def self.run_local(carnet_name = nil)
    if colored_prompt.yes?(yellow(Loc.get("add_to_sync_question")))
      require_relative "ie_command"
      return IeCommand.add_to(carnet_name)
    end

    song_id = song_infos!(pick_song)["id"].strip
    carnet_folder = pick_carnet(carnet_name)
    puts(add_to_tdm(carnet_folder, song_id) ? success(Loc.get("add_to_tdm_added")) : gray(Loc.get("add_to_tdm_already")))
  end

  # Carnet désigné, sinon courant, sinon choisi dans la liste.
  def self.pick_carnet(carnet_name)
    return SongResolver.resolve_carnet_folder(carnet_name) if carnet_name

    Session.carnet || SongResolver.select_song(Loc.get("add_to_pick_carnet"), CarnetBuilder.all_carnets(AppConfig.songbooks_dir))
  end

  # Chanson désignée, sinon courante, sinon choisie dans la liste de toutes les chansons.
  def self.pick_song(song_name = nil)
    return SongResolver.resolve_song_folder(song_name) if song_name

    Session.song || SongResolver.select_song(Loc.get("add_to_pick_song"), CarnetBuilder.all_songs(AppConfig.songs_dir))
  end

  # `id` de la fiche d'une chanson (abandon s'il manque).
  def self.song_infos!(song_folder)
    infos_path = FileFinder.find(song_folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
    abort Loc.get("tuto_editions_no_id") if infos["id"].to_s.strip.empty?

    infos
  end

  def self.in_tdm?(carnet_folder, song_id)
    SongbookSite.tdm_ids(carnet_folder).include?(song_id)
  end

  # Insère `- <id>` avant la 1re ligne d'id alphabétiquement supérieure (fin de liste
  # sinon). `false` si l'id y est déjà.
  def self.add_to_tdm(carnet_folder, song_id)
    tdm_path = FileFinder.find(carnet_folder, :tdm) || File.join(carnet_folder, "c.tdm")
    lines = File.exist?(tdm_path) ? File.read(tdm_path).split("\n", -1) : []
    lines.pop if lines.last == ""
    ids = lines.map { |l| l[/\A-\s*(\S+)/, 1] }
    return false if ids.include?(song_id)

    idx = ids.index { |id| id && id > song_id }
    idx ||= (ids.rindex { |id| id } || -1) + 1
    lines.insert(idx, "- #{song_id}")
    File.write(tdm_path, "#{lines.join("\n")}\n")
    true
  end

  # `id` de la fiche du carnet — demandé et ajouté en tête de fiche s'il manque.
  def self.ensure_carnet_id(carnet_folder)
    infos_path = FileFinder.find(carnet_folder, :inf) || File.join(carnet_folder, "c.infos")
    content = File.exist?(infos_path) ? File.read(infos_path) : ""
    id = content[/^id:\s*(\S.*?)\s*$/, 1]
    return id if id

    id = colored_prompt.ask(yellow(Loc.get("add_to_carnet_id_question")), default: CarnetBuilder.slugify(File.basename(carnet_folder))) { |q| q.required true }.strip
    File.write(infos_path, "id: #{id}\n#{content}")
    id
  end
end
