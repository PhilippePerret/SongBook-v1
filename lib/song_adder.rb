# frozen_string_literal: true

require "yaml"
require_relative "ansi_colors"
require_relative "app_config"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "icare_editions"
require_relative "locale"
require_relative "session"
require_relative "song_resolver"
require_relative "tuto_video"

# `songbook ie add-to [carnet]` : ajoute une chanson (courante, sinon choisie) à un carnet
# (désigné, courant, sinon choisi) — `.tdm` du carnet (ordre alphabétique des ids),
# donnée `carnets` du site des éditions, vidéo provisoire du tutoriel.
module SongAdder
  extend AnsiColors

  # `sync:` (`ie add-to`) : synchronise le site des éditions à la fin.
  def self.run(carnet_name = nil, sync: false)
    song_folder = pick_song
    carnet_folder =
      if carnet_name then SongResolver.resolve_carnet_folder(carnet_name)
      else Session.carnet || SongResolver.select_song(Loc.get("add_to_pick_carnet"), CarnetBuilder.all_carnets(AppConfig.songbooks_dir))
      end

    song_infos = song_infos!(song_folder)
    song_id = song_infos["id"].to_s.strip

    puts(add_to_tdm(carnet_folder, song_id) ? success(Loc.get("add_to_tdm_added")) : gray(Loc.get("add_to_tdm_already")))

    carnet_id = ensure_carnet_id(carnet_folder)
    item = IcareEditions.create_song_item(song_folder)
    puts success(Loc.get("tuto_editions_created")) if item[:status] == :created
    puts(IcareEditions.add_carnet(item[:folder], carnet_id) ? success(Loc.get("add_to_editions_added")) : gray(Loc.get("add_to_editions_already")))

    puts gray(Loc.get("add_to_video_running"))
    case TutoVideo.produce(song_id, song_infos["title"].to_s, song_infos["performer"].to_s)
    when :created then puts success(Loc.get("add_to_video_created"))
    when :exists then puts gray(Loc.get("add_to_video_exists"))
    else warn Loc.get("add_to_video_failed")
    end

    upload = TutoVideo.upload(song_id)
    case upload
    when :uploaded then puts success(Loc.get("add_to_r2_uploaded"))
    else warn Loc.get("add_to_r2_failed")
    end

    synced = sync && IcareEditions.sync
    guide_next_steps(song_folder, carnet_folder, r2_done: upload != :failed, synced: synced)
  end

  # Chanson courante, sinon choisie dans la liste de toutes les chansons.
  def self.pick_song
    Session.song || SongResolver.select_song(Loc.get("add_to_pick_song"), CarnetBuilder.all_songs(AppConfig.songs_dir))
  end

  # `id` de la fiche d'une chanson (abandon s'il manque).
  def self.song_infos!(song_folder)
    infos_path = FileFinder.find(song_folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
    abort Loc.get("tuto_editions_no_id") if infos["id"].to_s.strip.empty?

    infos
  end

  # Fin de `add-to` : ouvre le dossier de la chanson, celui des vidéos et le `.tdm` du
  # carnet, puis liste les opérations qui restent à faire à la main (téléversement R2
  # et synchronisation seulement s'ils n'ont pas été faits).
  def self.guide_next_steps(song_folder, carnet_folder, r2_done: false, synced: false)
    system("open", song_folder)
    system("open", TutoVideo::CHANSONS_TUTOS_DIR)
    tdm_path = FileFinder.find(carnet_folder, :tdm)
    system("open", "-a", AppConfig.user_song_editor, tdm_path) if tdm_path

    puts
    puts yellow(Loc.get("add_to_next_steps"))
    steps = %w[add_to_step_tdm]
    steps << "add_to_step_r2" unless r2_done
    steps << "add_to_step_sync" unless synced
    steps.each_with_index do |key, i|
      puts "  #{i + 1}. #{format(Loc.get(key), IcareEditions::EDITIONS_DIR)}"
    end
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
