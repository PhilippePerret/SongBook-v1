# frozen_string_literal: true

require_relative "ansi_colors"
require_relative "app_config"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "icare_editions"
require_relative "locale"
require_relative "song_adder"
require_relative "song_resolver"
require_relative "songbook_site"
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
    covers: "ie_menu_covers",
  }.freeze

  def self.run(arg1 = nil, arg2 = nil, arg3 = nil)
    action =
      case [arg1, arg2]
      in ["sync", _] then :sync
      in ["create", "song"] then :create_song
      in ["open", "song"] then :open_song
      in ["upload", "tuto"] then :upload_tuto
      in ["add-to", _] then :add_to
      in ["create", "tuto"] then :create_tuto
      in ["create" | "update", "songbook" | "sb"] then :create_songbook
      in ["cover" | "covers", _] then :covers
      in [nil, _] then pick_action
      else abort "commande inconnue : ie #{[arg1, arg2].compact.join(" ")} (aide : songbook -h)"
      end
    return unless action

    target = %w[create update open upload].include?(arg1) ? arg3 : arg2
    send(action, action == :sync ? nil : target)
  end

  def self.pick_action
    choices = ACTIONS.map { |value, key| { name: Loc.get(key), value: value } }
    choices << { name: Loc.get("stop_here"), value: nil }
    colored_prompt.select(yellow(Loc.get("ie_menu_question")), choices, show_help: false, per_page: choices.size)
  end

  def self.sync(_ = nil)
    IcareEditions.sync
  end

  # Chanson (courante, sinon choisie) ajoutée au carnet (désigné, courant, sinon choisi).
  def self.add_to(carnet_name = nil)
    song_folder = SongAdder.pick_song
    add_song(song_folder, [SongAdder.pick_carnet(carnet_name)])
  end

  # Chanson ajoutée aux carnets cochés.
  def self.create_song(song_name = nil)
    song_folder = SongAdder.pick_song(song_name)
    add_song(song_folder, pick_carnets(SongAdder.song_infos!(song_folder)["id"].strip))
  end

  # Chanson sur le site des éditions (dossier, annonce du tuto .mp4 + R2), ajoutée à la
  # table des matières de chaque carnet de `carnet_folders` (ouverte pour vérifier la
  # position), carnets créés/actualisés sur le site, puis synchronisation après
  # vérification. Rien de ce qui existe n'est touché.
  def self.add_song(song_folder, carnet_folders)
    infos = SongAdder.song_infos!(song_folder)
    id = infos["id"].strip
    to_open = []
    new_covers = []
    TutoVideo.batch do
      to_open << ensure_song(song_folder, infos)[:folder]
      add_to_carnets(id, carnet_folders, to_open, new_covers)
    end

    to_open.each { |folder| system("open", folder) }
    synced = confirm_and_sync(new_covers)

    puts
    names = carnet_folders.map { |folder| "« #{SongResolver.display_name(folder)} »" }.join(", ")
    puts success(format(Loc.get("ie_song_created_in"), infos["title"].to_s, names.empty? ? "-" : names))
    puts(synced ? success(Loc.get("ie_site_synced")) : orange(Loc.get("ie_site_not_synced")))
  end

  def self.add_to_carnets(id, carnet_folders, to_open, new_covers)
    carnet_folders.each do |carnet_folder|
      puts blue(SongResolver.display_name(carnet_folder))
      carnet_id = SongAdder.ensure_carnet_id(carnet_folder)
      if SongAdder.add_to_tdm(carnet_folder, id)
        puts success(Loc.get("add_to_tdm_added"))
        system("open", "-a", AppConfig.user_song_editor, FileFinder.find(carnet_folder, :tdm))
      else
        puts gray(Loc.get("add_to_tdm_already"))
      end
      new_covers << [carnet_folder, carnet_id] if ensure_songbook(carnet_folder, carnet_id)
      to_open << SongbookSite.folder_for(carnet_id)
    end
  end

  # Dossier de la chanson sur le site, carnet `carnet_id` associé, annonce du tuto :
  # seulement ce qui manque. `say` reçoit chaque ligne affichée ; `quiet:` tait ce qui
  # existait déjà.
  def self.ensure_song(song_folder, infos, carnet_id = nil, say: method(:puts), quiet: false)
    item = IcareEditions.create_song_item(song_folder)
    if item[:status] == :created
      say.(success(Loc.get("tuto_editions_created")))
    elsif !quiet
      say.(gray(Loc.get("tuto_editions_exists")))
    end
    say.(success(Loc.get("add_to_editions_added"))) if carnet_id && IcareEditions.add_carnet(item[:folder], carnet_id)
    ensure_tuto(infos["id"].strip, infos, say: say, quiet: quiet)
    item
  end

  # `.mp4` de l'annonce produit et téléversé sur R2, seulement s'ils manquent. `say`
  # reçoit chaque ligne affichée ; `quiet:` tait ce qui existait déjà.
  def self.ensure_tuto(id, infos, say: method(:puts), quiet: false)
    say.(gray(Loc.get("add_to_video_running"))) unless File.exist?(TutoVideo.path_for(id))
    case TutoVideo.produce(id, infos["title"].to_s, infos["performer"].to_s)
    when :created then say.(success(Loc.get("add_to_video_created")))
    when :exists then say.(gray(Loc.get("add_to_video_exists"))) unless quiet
    else return say.(error(Loc.get("add_to_video_failed")))
    end

    if TutoVideo.on_r2?(id)
      say.(gray(Loc.get("ie_r2_exists"))) unless quiet
    elsif TutoVideo.upload(id) == :uploaded
      say.(success(Loc.get("add_to_r2_uploaded")))
    else
      say.(error(Loc.get("add_to_r2_failed")))
    end
  end

  # Liste à cocher de tous les carnets, ceux qui contiennent déjà la chanson précochés.
  def self.pick_carnets(song_id)
    carnets = CarnetBuilder.all_carnets(AppConfig.songbooks_dir)
    choices = carnets.map { |c| { name: c[:title] ? "#{c[:name]} (#{c[:title]})" : c[:name], value: c[:folder] } }
    defaults = carnets.each_index.select { |i| SongAdder.in_tdm?(carnets[i][:folder], song_id) }.map { |i| i + 1 }
    colored_prompt.multi_select(yellow(Loc.get("ie_pick_carnets")), choices, default: defaults, echo: false, show_help: false, per_page: 20)
  end

  def self.open_song(song_name = nil)
    id = SongAdder.song_infos!(SongAdder.pick_song(song_name))["id"].strip
    system("open", format(IcareEditions::SONG_PAGE_URL, id))
  end

  def self.upload_tuto(song_name = nil)
    id = SongAdder.song_infos!(SongAdder.pick_song(song_name))["id"].strip

    case TutoVideo.upload(id)
    when :uploaded then puts success(Loc.get("add_to_r2_uploaded"))
    when :missing then warn Loc.get("ie_tuto_missing")
    else warn Loc.get("add_to_r2_failed")
    end
  end

  def self.create_tuto(song_name = nil)
    infos = SongAdder.song_infos!(SongAdder.pick_song(song_name))
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

  # Dossier du carnet sur le site (data.yaml, texte.md, tdm.yaml, couverture,
  # miniature), ouvert dans le Finder pour vérification avant synchronisation.
  def self.create_songbook(carnet_name = nil)
    carnet_folder = SongAdder.pick_carnet(carnet_name)
    carnet_id = SongAdder.ensure_carnet_id(carnet_folder)
    new_covers = TutoVideo.batch { ensure_songbook(carnet_folder, carnet_id) }
    system("open", SongbookSite.folder_for(carnet_id))
    confirm_and_sync(new_covers ? [[carnet_folder, carnet_id]] : [])
  end

  # Dossier du carnet sur le site, chansons de sa table des matières (dossier sur le
  # site, carnet associé, annonce du tuto), couverture et miniature : seulement ce qui
  # manque. `true` si couverture et miniature viennent d'être produites.
  def self.ensure_songbook(carnet_folder, carnet_id)
    if SongbookSite.create(carnet_folder, carnet_id) == :exists
      puts gray(Loc.get("ie_songbook_exists"))
      puts success(Loc.get("add_to_site_tdm_updated")) if SongbookSite.write_tdm(carnet_folder, carnet_id)
    else
      puts success(Loc.get("ie_songbook_created"))
    end
    ensure_songs(carnet_folder, carnet_id)
    return false if SongbookSite.covers_exist?(carnet_id)

    status = SongbookSite.make_covers(carnet_folder, carnet_id)
    report_covers(status)
    status == :created
  end

  # Chaque chanson du `.tdm` du carnet : nom affiché seulement si quelque chose est
  # fait (ou échoue) pour elle.
  def self.ensure_songs(carnet_folder, carnet_id)
    folders = SongbookSite.song_folders_by_id
    SongbookSite.tdm_ids(carnet_folder).each do |id|
      song_folder = folders[id]
      next warn(error(format(Loc.get("ie_song_unknown"), id))) unless song_folder

      shown = false
      say = lambda do |line|
        puts blue(SongResolver.display_name_with_performer(song_folder)) unless shown
        shown = true
        puts "  #{line}"
      end
      ensure_song(song_folder, SongAdder.song_infos!(song_folder), carnet_id, say: say, quiet: true)
    end
  end

  # Validation des couvertures de chaque carnet de `carnets` (`[dossier, id]`), puis
  # seulement accord de synchronisation.
  # `true` si le site a été synchronisé.
  def self.confirm_and_sync(carnets)
    carnets.each { |folder, id| return false unless covers_valid?(folder, id) }
    return false unless colored_prompt.yes?(yellow(Loc.get("ie_songbook_sync_question")), default: true)

    IcareEditions.sync
  end

  # Non -> renoncer, reconstruire couverture et miniature (puis redemander) ou les
  # accepter quand même.
  def self.covers_valid?(carnet_folder, carnet_id)
    name = SongResolver.display_name(carnet_folder)
    loop do
      return true if colored_prompt.yes?(yellow(format(Loc.get("ie_covers_valid_question"), name)), default: true)

      choices = [
        { name: orange(Loc.get("ie_covers_give_up")), value: :give_up },
        { name: Loc.get("ie_covers_rebuild"), value: :rebuild },
        { name: Loc.get("ie_covers_ok"), value: :ok },
      ]
      case colored_prompt.select(yellow(format(Loc.get("ie_covers_invalid_question"), name)), choices, show_help: false)
      when :give_up then return false
      when :ok then return true
      else report_covers(SongbookSite.make_covers(carnet_folder, carnet_id))
      end
    end
  end

  # `ie cover`/`ie covers` : couverture et miniature du carnet pour le site.
  def self.covers(carnet_name = nil)
    carnet_folder = SongAdder.pick_carnet(carnet_name)
    carnet_id = SongAdder.ensure_carnet_id(carnet_folder)
    report_covers(SongbookSite.make_covers(carnet_folder, carnet_id))
    system("open", SongbookSite.folder_for(carnet_id))
  end

  def self.report_covers(status)
    case status
    when :created then puts success(Loc.get("ie_covers_created"))
    when :no_pdf then warn Loc.get("ie_covers_no_pdf")
    else warn Loc.get("ie_covers_failed")
    end
  end
end
