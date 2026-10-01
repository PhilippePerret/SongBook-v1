# frozen_string_literal: true

require_relative "ansi_colors"
require_relative "icare_editions"
require_relative "locale"
require_relative "song_adder"
require_relative "tuto_video"

# `songbook ie [action]` : opérations liées au site des éditions Icare — menu si
# aucune action n'est donnée.
module IeCommand
  extend AnsiColors

  ACTIONS = {
    sync: "ie_menu_sync",
    create_song: "ie_menu_create_song",
    open_song: "ie_menu_open_song",
    upload_tuto: "ie_menu_upload_tuto",
    add_to: "ie_menu_add_to",
    create_tuto: "ie_menu_create_tuto",
    create_songbook: "ie_menu_create_songbook",
  }.freeze

  def self.run(arg1 = nil, arg2 = nil)
    action =
      case [arg1, arg2]
      in ["sync", _] then :sync
      in ["create", "song"] then :create_song
      in ["open", "song"] then :open_song
      in ["upload", "tuto"] then :upload_tuto
      in ["add-to", _] then :add_to
      in ["create", "tuto"] then :create_tuto
      in ["create", "songbook" | "sb"] then :create_songbook
      in [nil, _] then pick_action
      else abort "commande inconnue : ie #{[arg1, arg2].compact.join(" ")} (aide : songbook -h)"
      end
    return unless action

    send(action, arg1 == "add-to" ? arg2 : nil)
  end

  def self.pick_action
    choices = ACTIONS.map { |value, key| { name: Loc.get(key), value: value } }
    choices << { name: Loc.get("stop_here"), value: nil }
    colored_prompt.select(yellow(Loc.get("ie_menu_question")), choices, show_help: false)
  end

  def self.sync(_ = nil)
    IcareEditions.sync
  end

  def self.add_to(carnet_name = nil)
    SongAdder.run(carnet_name, sync: true)
  end

  # Dossier de la chanson sur le site des éditions.
  def self.create_song(_ = nil)
    result = IcareEditions.create_song_item(SongAdder.pick_song)
    case result[:status]
    when :created then puts success(Loc.get("tuto_editions_created"))
    when :exists then puts gray(Loc.get("tuto_editions_exists"))
    when :no_id then abort Loc.get("tuto_editions_no_id")
    end
  end

  def self.open_song(_ = nil)
    id = SongAdder.song_infos!(SongAdder.pick_song)["id"].strip
    system("open", format(IcareEditions::SONG_PAGE_URL, id))
  end

  def self.upload_tuto(_ = nil)
    id = SongAdder.song_infos!(SongAdder.pick_song)["id"].strip

    case TutoVideo.upload(id)
    when :uploaded then puts success(Loc.get("add_to_r2_uploaded"))
    when :missing then warn Loc.get("ie_tuto_missing")
    else warn Loc.get("add_to_r2_failed")
    end
  end

  def self.create_tuto(_ = nil)
    infos = SongAdder.song_infos!(SongAdder.pick_song)
    id = infos["id"].strip
    force = false
    if File.exist?(TutoVideo.path_for(id))
      force = colored_prompt.yes?(yellow(Loc.get("ie_tuto_overwrite_question")), default: false)
      return unless force
    end

    puts gray(Loc.get("add_to_video_running"))
    case TutoVideo.produce(id, infos["title"].to_s, infos["performer"].to_s, force: force)
    when :created then puts success(Loc.get("add_to_video_created"))
    else warn Loc.get("add_to_video_failed")
    end
  end

  def self.create_songbook(_ = nil)
    puts gray(Loc.get("ie_create_songbook_pending"))
  end
end
