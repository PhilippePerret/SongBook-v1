# frozen_string_literal: true

require "tty-prompt"
require_relative "sacem_client"
require_relative "rights_manager"
require_relative "rights_report"
require_relative "rights_mailer"
require_relative "song_resolver"
require_relative "songs_list"
require_relative "file_finder"
require_relative "session"
require_relative "app_config"
require_relative "locale"
require_relative "ansi_colors"

# `songbook rights`/`droits` — menu défini par Phil (2026-09-22, réordonné/refondu
# 2026-09-22 : "il faut demander le contexte (carnet ou chanson, puis choix)", suivi
# passé en premier "la recherche de l'éditeur sera plus rare que le suivi") :
#   "Que voulez-vous faire ?"
#   1. Suivi des demandes de droits
#      - Afficher un rapport [HTML] de l'état des demandes [demande le carnet]
#      - Envoyer des demandes de publication [premier contact, relance]
#      - Modifier le statut d'une chanson
#      - Ouvrir le mail type / le mail de relance
#   2. Rechercher les éditeurs -> demande TOUJOURS le contexte (chanson courante/carnet
#      courant si actifs, ou choisir une chanson/un carnet/toute la bibliothèque)
module RightsCli
  extend AnsiColors

  def self.run
    prompt = colored_prompt
    choice = prompt.select(blue("Que voulez-vous faire ?"), [
      { name: "Suivi des demandes de droits", value: :tracking },
      { name: "Rechercher les éditeurs", value: :search },
      { name: "Ne rien faire", value: nil },
    ], show_help: false)

    case choice
    when :tracking then run_tracking_menu
    when :search then run_search_menu
    end
  rescue Interrupt
    puts
  end

  def self.run_search_menu
    prompt = colored_prompt
    choice = prompt.select(blue("Rechercher les éditeurs"), [
      { name: "Chercher les éditeurs d'un carnet", value: :carnet },
      { name: "Chercher l'éditeur d'une chanson", value: :song },
      { name: "Chercher sur toute la bibliothèque", value: :all },
    ], show_help: false)

    case choice
    when :carnet
      carnet = SongResolver.resolve_carnet_folder(nil)
      folders = SongsList.entries(carnet_folder: carnet).map { |e| File.join(AppConfig.songs_dir, e[:folder]) }
      run_search(folders, label: SongResolver.display_name(carnet))
    when :song
      folder = SongResolver.resolve_song_folder(nil)
      run_search([folder], label: SongResolver.display_name(folder))
    when :all
      folders = SongsList.entries.map { |e| File.join(AppConfig.songs_dir, e[:folder]) }
      run_search(folders, label: "toute la bibliothèque")
    end
  rescue Interrupt
    puts
  end

  # --- Recherche d'éditeur (Sacem) -----------------------------------------------------

  # `force:` demandé à chaque fois (même pour 1 seule chanson) plutôt que déduit — c'est
  # la "demande explicite" (Phil, 2026-09-22) qui autorise à écraser/re-chercher un
  # `music_publisher` déjà renseigné, jamais un défaut supposé.
  def self.run_search(folders, label:)
    return puts error("👎 aucune chanson à traiter") unless folders&.any?

    prompt = colored_prompt
    if folders.size > 1
      puts gray("#{folders.size} chanson(s) à vérifier sur le répertoire Sacem (#{label}) — recherche par navigateur, quelques secondes par chanson.")
      return unless prompt.yes?(blue("Continuer ?"))
    end
    force = prompt.yes?(blue("Relancer aussi la recherche pour les chansons ayant déjà un éditeur renseigné ?"), default: false)

    client = SacemClient.new
    results = []
    folders.each_with_index do |folder, i|
      print "[#{i + 1}/#{folders.size}] #{SongResolver.display_name(folder)} … "
      STDOUT.flush
      results << RightsManager.process_song(client, folder, force: force)
      puts status_line(results.last)
    end
    client.close

    RightsManager.append_log(results)
    report_search(results)
  rescue Interrupt
    client&.close
    puts
  end

  def self.status_line(r)
    case r.status
    when :ok then success("👍 #{r.message}")
    when :skipped then gray(r.message)
    when :ambiguous then orange("🤔 Ambigu")
    when :not_found then error("👎 Pas trouvé")
    else error("👎 Erreur")
    end
  end

  # "être très clair sur ce qu'il faut faire" (Phil, 2026-09-22) : chaque problème listé
  # avec l'ACTION concrète attendue (déjà dans `r.message`, voir `RightsManager`).
  def self.report_search(results)
    problems = results.reject { |r| %i[ok skipped].include?(r.status) }
    return puts success("👍 Éditeur trouvé (ou déjà renseigné) pour toutes les chansons.") if problems.empty?

    puts
    puts blue("Chansons à vérifier à la main :")
    problems.each_with_index { |r, i| puts error("#{i + 1}. #{r.title} — #{r.message}") }
    puts gray("Détail dans #{RightsManager.log_path}")
  end

  # --- Suivi des demandes de droits ----------------------------------------------------

  def self.run_tracking_menu
    prompt = colored_prompt
    choice = prompt.select(blue("Suivi des demandes de droits — que faire ?"), [
      { name: "Afficher un rapport (HTML) de l'état des demandes", value: :report },
      { name: "Envoyer des demandes de publication", value: :mail },
      { name: "Modifier le statut d'une chanson", value: :change_status },
      { name: "Modifier le mail type de demande de droits", value: :open_first_contact },
      { name: "Modifier le mail de relance", value: :open_relance },
      { name: "Retour", value: nil },
    ], show_help: false)

    case choice
    when :report then run_report
    when :mail then run_mail
    when :change_status then run_change_status
    when :open_first_contact then open_mail_template(:first_contact)
    when :open_relance then open_mail_template(:relance)
    end
  rescue Interrupt
    puts
  end

  # `sent` exclu (Phil, 2026-09-22, "sauf sent ou relance") : ce statut n'est affecté
  # QUE par un envoi réel (`RightsMailer.send_group`), jamais choisi à la main — une
  # relance n'est pas un statut mais un événement (voir `RightsMailer::TEMPLATE_FILES`).
  MANUAL_STATUSES = (RightsManager::STATUSES - ["sent"]).freeze

  def self.run_change_status
    folder = SongResolver.resolve_song_folder(nil)
    infos_path = FileFinder.find(folder, :inf)
    return puts error("👎 pas de fichier .infos/.inf pour cette chanson") unless infos_path

    prompt = colored_prompt
    choices = MANUAL_STATUSES.map { |s| { name: RightsReport::STATUS_LABELS.fetch(s, s), value: s } }
    status = prompt.select(blue("Nouveau statut pour « #{SongResolver.display_name(folder)} » :"), choices, show_help: false)

    label = RightsReport::STATUS_LABELS.fetch(status, status)
    RightsManager.append_rights_status(infos_path, status, "statut changé manuellement : #{label}")
    puts success("👍 statut mis à jour : #{label}")
  rescue Interrupt
    puts
  end

  def self.open_mail_template(kind)
    path = File.join(RightsMailer::TEMPLATES_DIR, RightsMailer::TEMPLATE_FILES.fetch(kind))
    system("open", "-a", AppConfig.user_song_editor, path)
  end

  def self.run_report
    carnet = SongResolver.resolve_carnet_folder(nil)
    path = RightsReport.generate(carnet)
    system("open", path)
    puts success("👍 rapport généré et ouvert : #{path}")
  end

  # Un email par ÉDITEUR (pas par chanson) — regroupe les chansons du carnet qu'il
  # édite. Action proposée par groupe selon son statut actuel (premier contact si
  # jamais contacté, relance sinon) — jamais choisie automatiquement, "après validation"
  # (Phil, 2026-09-22) : une confirmation globale juste avant l'envoi réel.
  def self.run_mail
    prompt = colored_prompt
    carnet = SongResolver.resolve_carnet_folder(nil)

    groups = RightsMailer.groups_for_carnet(carnet)
    return puts gray("Aucun éditeur avec email connu pour ce carnet (lancer d'abord « Rechercher les éditeurs »).") if groups.empty?

    planned = []
    groups.each do |g|
      all_none = g.songs.all? { |s| s[:status] == "none" }
      puts blue("#{g.publisher_name} (#{g.publisher_email}) — #{g.songs.map { |s| s[:title] }.join(", ")}")
      action = prompt.select("  Action :", [
        { name: all_none ? "Premier contact" : "Relance", value: all_none ? :first_contact : :relance },
        { name: all_none ? "Relance (statut déjà avancé ?)" : "Premier contact (forcer)", value: all_none ? :relance : :first_contact },
        { name: "Ignorer", value: nil },
      ], show_help: false)
      planned << [g, action] if action
    end
    return puts gray("Rien à envoyer.") if planned.empty?

    puts
    puts blue("#{planned.size} email(s) vont être envoyés :")
    planned.each { |g, kind| puts "  - #{g.publisher_email} (#{kind == :first_contact ? "premier contact" : "relance"})" }
    return puts gray("Annulé.") unless prompt.yes?(blue("Confirmer l'envoi ?"))

    planned.each do |g, kind|
      RightsMailer.send_group(g, kind)
      puts success("👍 envoyé à #{g.publisher_email}")
    rescue StandardError => e
      puts error("👎 échec envoi #{g.publisher_email} : #{e.message}")
    end
  rescue Interrupt
    puts
  end
end
