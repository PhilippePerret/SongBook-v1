# frozen_string_literal: true

require "date"
require "fileutils"
require "tty-prompt"
require "tty-spinner"
require_relative "sacem_client"
require_relative "rights_manager"
require_relative "rights_report"
require_relative "rights_mailer"
require_relative "rights_expiry"
require_relative "publishers_db"
require_relative "song_resolver"
require_relative "songs_list"
require_relative "file_finder"
require_relative "session"
require_relative "app_config"
require_relative "locale"
require_relative "ansi_colors"

# `songbook rights`/`droits` — menu défini par Phil (2026-09-22, réordonné/refondu
# 2026-09-22 : "il faut demander le contexte (carnet ou chanson, puis choix)", suivi
# passé en premier "la recherche de l'éditeur sera plus rare que le suivi" ; envoi
# séparé du suivi 2026-09-23) :
#   "Que voulez-vous faire ?"
#   1. Suivi des demandes d'autorisation
#      - Afficher un rapport [HTML] de l'état des demandes [demande le carnet]
#      - Définir le statut d'une chanson
#      - Passer en revue les ambiguïtés [si un log en attente]
#   2. Envoi des demandes d'autorisation
#      - Envoyer des demandes de publication [email, premier contact/relance]
#      - Envoyer une demande d'autorisation par la poste [lettre + adresse à imprimer]
#      - Ouvrir le mail type / le mail de relance
#   3. Chercher les éditeurs -> demande TOUJOURS le contexte (chanson courante/carnet
#      courant si actifs, ou choisir une chanson/un carnet/toute la bibliothèque)
#   4. Ouvrir la base des éditeurs [fichier YAML partagé, voir `PublishersDb`]
module RightsCli
  extend AnsiColors

  def self.run
    prompt = colored_prompt
    choices = [
      { name: "Suivi des demandes d'autorisation", value: :tracking },
      { name: "Envoi des demandes d'autorisation", value: :send },
      { name: "Chercher les éditeurs", value: :search },
      { name: "Ouvrir la base des éditeurs", value: :open_db },
      { name: orange("Renoncer"), value: nil },
    ]
    choice = prompt.select(yellow("Que voulez-vous faire ?"), choices, show_help: false, per_page: choices.size)

    case choice
    when :tracking then run_tracking_menu
    when :send then run_send_menu
    when :search then run_search_menu
    when :open_db then open_publishers_db
    end
  rescue Interrupt
    puts
  end

  def self.run_search_menu
    prompt = colored_prompt
    choices = [
      { name: "Chercher les éditeurs d'un carnet", value: :carnet },
      { name: "Chercher l'éditeur d'une chanson", value: :song },
      { name: "Chercher sur toute la bibliothèque", value: :all },
      { name: orange("Revenir"), value: :back },
    ]
    choice = prompt.select(yellow("Rechercher les éditeurs"), choices, show_help: false, per_page: choices.size)

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
    when :back then run
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
      return unless prompt.yes?(yellow("Continuer ?"))
    end
    force = !prompt.yes?(yellow("Dois-je passer les chansons déjà traitées ?"), default: true)

    client = SacemClient.new
    begin
      # Les déjà traitées (`:skipped`) ne s'affichent pas — juste du bruit, aucune info
      # utile (Phil, 2026-09-22, "ça pollue l'affichage, c'est TOUT ce que ça fait").
      # Spinner pendant chaque recherche (navigateur, plusieurs secondes) — sinon donne
      # l'impression que c'est bloqué (Phil, 2026-09-22) ; `clear: true` : disparaît dès
      # qu'on connaît le résultat, remplacé par la ligne finale (ou rien, si skipped).
      results = []
      folders.each_with_index do |folder, i|
        label = SongResolver.display_name(folder)
        spinner = TTY::Spinner.new(blue("[:spinner] [#{i + 1}/#{folders.size}] #{label}"), format: :dots, clear: true)
        spinner.auto_spin
        result = RightsManager.process_song(client, folder, force: force)
        spinner.stop

        results << result
        next if result.status == :skipped

        puts "[#{i + 1}/#{folders.size}] #{label} … #{status_line(result)}"
      end

      RightsManager.append_log(results)
      report_search(results)
      review_ambiguous_if_wanted(client, results)
    ensure
      client.close
    end
  rescue Interrupt
    puts
  end

  # "je pensais que tu allais proposer, sur les cas ambigus, de les fixer ensemble"
  # (Phil, 2026-09-22) — `client` gardé ouvert par `run_search` exprès pour ça (éviter
  # de relancer un navigateur juste pour la revue qui suit).
  def self.review_ambiguous_if_wanted(client, results)
    ambiguous = results.select { |r| r.status == :ambiguous && r.candidates }
    return if ambiguous.empty?
    return unless colored_prompt.yes?(yellow("Voulez-vous que nous regardions les ambiguïtés ?"))

    review_ambiguous(client, ambiguous)
  end

  # Passe en revue une liste de `Result` `:ambiguous`, un par un : propose les fiches
  # Sacem trouvées (`r.candidates`), l'user choisit — jamais deviné (Phil, 2026-09-22,
  # "tu ne devines RIEN"). Partagé entre la relance juste après une recherche et "Passer
  # en revue les ambiguïtés" (depuis le log, voir `run_review_ambiguous_from_log`).
  # UN cas à la fois (Phil, 2026-09-22, "chaque cas devrait être proposé tout seul") —
  # même règle que `run_review_ambiguous_from_log`.
  def self.review_ambiguous(client, ambiguous_results)
    prompt = colored_prompt
    ambiguous_results.each_with_index do |r, i|
      choices = r.candidates.map do |it|
        { name: candidate_label(RightsManager.editor_of(it)), value: it }
      end
      choices << { name: "Entrer l'éditeur à la main", value: :manual }
      choices << { name: orange("Ignorer"), value: nil }

      chosen = prompt.select(yellow("« #{r.title} » — quel éditeur ?"), choices, show_help: false, per_page: choices.size)
      case chosen
      when :manual
        enter_publisher_manually(prompt, r.folder)
      when nil
        # rien à faire
      else
        name = RightsManager.resolve_ambiguous!(client, r.folder, chosen)
        if name
          puts success("👍 #{r.title} — #{name}")
        else
          puts error("👎 #{r.title} — fiche détail illisible")
          enter_publisher_manually(prompt, r.folder)
        end
      end

      next_up = ambiguous_results.size - i - 1
      break if next_up.zero?
      break unless prompt.yes?(yellow("Chanson suivante (encore #{next_up}) ?"), default: true)
    end
  rescue Interrupt
    puts
  end

  # Éditeur EN TÊTE (c'est ce qu'on choisit, pas la chanson) — jamais le titre du
  # candidat : les candidats à titre différent ("LOVE VERSION"...) sont filtrés en amont
  # (`RightsManager.process_song`/`pending_ambiguous_from_log`), plus jamais proposés ici
  # (Phil, 2026-09-22, "je veux plus avoir un 'Love Version'"). Un candidat a parfois
  # PLUSIEURS éditeurs dans un seul champ texte ("SONY MUSIC PUBLISHING (FRANCE),
  # KLUGERPARTNERS") — recopier tel quel le rendrait indiscernable d'un candidat à un
  # seul éditeur qui partage juste un nom en commun ; signalé explicitement.
  def self.enter_publisher_manually(prompt, folder)
    infos_path = FileFinder.find(folder, :inf)
    return puts error("👎 pas de fichier .infos/.inf pour cette chanson") unless infos_path

    name = prompt.ask(yellow("Nom de l'éditeur :")) { |q| q.required true }
    ipi = prompt.ask(yellow("IPI (rien si inconnu) :"))
    address = prompt.ask(yellow("Adresse (rien si inconnue) :"))
    email = prompt.ask(yellow("Email (rien si inconnu) :"))

    RightsManager.write_publisher_manual!(infos_path, name: name, ipi: ipi, address: address, email: email)
    puts success("👍 éditeur enregistré à la main : #{name}")
  rescue Interrupt
    puts
  end

  def self.candidate_label(editor)
    editors = editor.to_s.split(/,\s*/).map(&:strip).reject(&:empty?)
    return "éditeur inconnu" if editors.empty?
    return editors.first if editors.size == 1

    "#{editors.size} éditeurs : #{editors.join(", ")}"
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

  # --- Suivi des demandes d'autorisation ------------------------------------------------

  def self.run_tracking_menu
    prompt = colored_prompt
    choices = [
      { name: "Afficher un rapport de l'état des droits", value: :report },
      { name: "Définir le statut d'une chanson", value: :change_status },
    ]
    choices << { name: "Passer en revue les ambiguïtés", value: :review_ambiguous } if File.exist?(RightsManager.log_path)
    choices << { name: orange("Revenir"), value: :back }

    choice = prompt.select(yellow("Suivi des demandes d'autorisation — que faire ?"), choices, show_help: false, per_page: choices.size)

    case choice
    when :report then run_report
    when :change_status then run_change_status
    when :review_ambiguous then run_review_ambiguous_from_log
    when :back then run
    end
  rescue Interrupt
    puts
  end

  # --- Envoi des demandes d'autorisation -------------------------------------------------

  def self.run_send_menu
    prompt = colored_prompt
    choices = [
      { name: "Envoyer des demandes de publication", value: :mail },
      { name: "Envoyer une demande d'autorisation par la poste", value: :postal },
      { name: "Modifier le mail type de demande de droits", value: :open_first_contact },
      { name: "Modifier le mail de relance", value: :open_relance },
      { name: orange("Revenir"), value: :back },
    ]

    choice = prompt.select(yellow("Envoi des demandes d'autorisation — que faire ?"), choices, show_help: false, per_page: choices.size)

    case choice
    when :mail then run_mail
    when :postal then run_postal_request
    when :open_first_contact then open_mail_template(:first_contact)
    when :open_relance then open_mail_template(:relance)
    when :back then run
    end
  rescue Interrupt
    puts
  end

  # Reprend les chansons repérées `[ambiguous]` dans le log — RE-recherchées à neuf
  # (`RightsManager.process_song`, jamais les hrefs sauvés : tokens de session Sacem,
  # invalides d'un run à l'autre) plutôt que de faire confiance au texte du log lui-même.
  # La LISTE vient du `.log` (texte déjà en main, aucune recherche) — une recherche live
  # n'a lieu que pour la chanson EFFECTIVEMENT choisie, au moment de confirmer un choix
  # précis (Phil, 2026-09-22, "les ambiguïtés doivent être relevées dans le fichier .log,
  # pas rechercher à nouveau").
  # UN cas à la fois, jamais un déroulé automatique de tous (Phil, 2026-09-22, "chaque
  # cas devrait être proposé tout seul") : point d'arrêt après CHAQUE chanson (résolue
  # automatiquement ou par choix), avant de passer à la suivante.
  def self.run_review_ambiguous_from_log
    entries = RightsManager.pending_ambiguous_from_log
    return puts success("👍 Aucune ambiguïté en attente.") if entries.empty?

    prompt = colored_prompt
    puts blue("#{entries.size} chanson(s) en attente.")

    client = SacemClient.new
    begin
      entries.each_with_index do |entry, i|
        review_one_from_log(prompt, client, entry)

        next_up = entries.size - i - 1
        break if next_up.zero?
        break unless prompt.yes?(yellow("Chanson suivante (encore #{next_up}) ?"), default: true)
      end
    ensure
      client.close
    end
  rescue Interrupt
    puts
  end

  def self.review_one_from_log(prompt, client, entry)
    return review_title_mismatch(prompt, client, entry) if entry[:candidates].empty?

    # Réduit à 1 seul candidat par `pending_ambiguous_from_log` (règle "superset", Phil,
    # 2026-09-22) : plus une vraie ambiguïté, résolu directement, jamais un faux choix
    # affiché à l'user pour une seule option.
    if entry[:candidates].size == 1
      chosen_index = entry[:candidates].first[:index]
    else
      choices = entry[:candidates].map { |c| { name: candidate_label(c[:editor]), value: c[:index] } }
      choices << { name: "Entrer l'éditeur à la main", value: :manual }
      choices << { name: orange("Ignorer"), value: nil }
      chosen_index = prompt.select(yellow("« #{entry[:title]} » — quel éditeur ? (depuis le log)"), choices, show_help: false, per_page: choices.size)
      return enter_publisher_manually(prompt, entry[:folder]) if chosen_index == :manual
      return unless chosen_index
    end

    outcome = RightsManager.resolve_ambiguous_from_log!(client, entry, chosen_index)
    if outcome[:ok]
      puts success("👍 #{entry[:title]} — #{outcome[:name]}")
      puts orange("  ⚠️  éditeur différent de celui vu dans le log — le répertoire Sacem a bougé entretemps, vérifie.") if outcome[:drifted]
    else
      puts error("👎 #{entry[:title]} — #{outcome[:message]}")
      enter_publisher_manually(prompt, entry[:folder])
    end
  end

  # Aucun candidat au titre exact (Phil, 2026-09-22, "quand l'ambiguïté repose sur le
  # titre... il faut que je puisse dire de quelle chanson il s'agit. Et que le programme
  # la recherche tout de suite") : propose les autres titres trouvés par Sacem + un titre
  # tapé à la main, cherche IMMÉDIATEMENT dessus une fois choisi. "Passer" toujours
  # disponible pour ne pas trancher maintenant.
  def self.review_title_mismatch(prompt, client, entry)
    others = entry[:other_titles].to_a
    puts orange("🤔 #{entry[:title]} : aucun résultat Sacem au titre exact.")

    choices = others.map { |t| { name: t, value: t } }
    choices << { name: "Autre titre (à taper)", value: :custom }
    choices << { name: orange("Passer"), value: nil }
    choice = prompt.select(yellow("  Sous quel titre est-elle enregistrée sur Sacem ?"), choices, show_help: false, per_page: choices.size)
    return unless choice

    real_title = choice == :custom ? prompt.ask(yellow("  Titre exact :")) { |q| q.required true } : choice

    result = RightsManager.process_song(client, entry[:folder], force: true, search_title: real_title)
    case result.status
    when :ok
      puts success("👍 #{entry[:title]} — #{result.message}")
    when :ambiguous
      result.candidates.nil? || result.candidates.empty? ? puts(error("👎 #{entry[:title]} — #{result.message}")) : review_ambiguous(client, [result])
    else
      puts error("👎 #{entry[:title]} — #{result.message}")
    end
  end

  # `sent` exclu (Phil, 2026-09-22, "sauf sent ou relance") : ce statut n'est affecté
  # QUE par un envoi réel (`RightsMailer.send_group`), jamais choisi à la main — une
  # relance n'est pas un statut mais un événement (voir `RightsMailer::TEMPLATE_FILES`).
  MANUAL_STATUSES = RightsManager::STATUSES.freeze

  def self.run_change_status
    folder = SongResolver.resolve_song_folder(nil)
    infos_path = FileFinder.find(folder, :inf)
    return puts error("👎 pas de fichier .infos/.inf pour cette chanson") unless infos_path

    prompt = colored_prompt
    infos = CarnetBuilder.parse_nested_infos(infos_path)
    choices = MANUAL_STATUSES.map { |s| status_choice(infos, s) }
    status = prompt.select(yellow("Nouveau statut pour « #{SongResolver.display_name(folder)} » :"), choices, show_help: false, per_page: choices.size)

    # "les droits ne sont jamais donnés à vie" (Phil, 2026-09-22) : la durée du contrat
    # n'a de sens qu'à partir du moment où il est signé — date de départ fixée à
    # aujourd'hui, jour de la saisie (= jour du contrat signé).
    extra = {}
    if status == "contract_signed"
      extra = { "duration" => ask_duration(prompt), "start_date" => Date.today.iso8601 }
    end

    label = RightsReport::STATUS_LABELS.fetch(status, status)
    RightsManager.append_rights_status(infos_path, status, nil, extra: extra)
    puts success("👍 statut mis à jour : #{label}")
  rescue Interrupt
    puts
  end

  def self.status_choice(infos, status)
    label = RightsReport::STATUS_LABELS.fetch(status, status)
    return { name: label, value: status } if RightsManager.status_selectable?(infos, status)

    idx = RightsManager::STAGE_ORDER.index(status)
    reached = RightsManager.stages_reached(infos)
    missing = RightsManager::STAGE_ORDER.first(idx).reject { |s| (reached & RightsManager::STAGE_BITS[s]) != 0 }
    reason = "nécessite d'abord : #{missing.map { |s| RightsReport::STATUS_LABELS.fetch(s, s) }.join(", ")}"
    { name: label, value: status, disabled: reason }
  end

  def self.ask_duration(prompt)
    loop do
      value = prompt.ask(yellow("Durée des droits accordés par ce contrat (ex: \"2 ans\", \"18 mois\") :")) { |q| q.required true }
      return value if value =~ RightsExpiry::DURATION_RE

      puts error("Format non reconnu — exemples valides : « 2 ans », « 18 mois », « 90 jours ».")
    end
  end

  # Aucun envoi automatisé (La Poste ne propose ça qu'après passage par un commercial,
  # Phil, 2026-09-23) : prépare juste la lettre et l'adresse à la main, puis ouvre le
  # dossier de la chanson et propose le site d'envoi de courrier en ligne de La Poste.
  POSTAL_DIR_NAME = "demande de droits"
  POSTAL_SITE_URL = "https://www.laposte.fr/envoi-courrier-en-ligne"

  def self.run_postal_request
    prompt = colored_prompt
    folder = SongResolver.resolve_song_folder(nil)
    infos_path = FileFinder.find(folder, :inf)
    return puts error("👎 pas de fichier .infos/.inf pour cette chanson") unless infos_path

    infos = CarnetBuilder.parse_nested_infos(infos_path)
    contacts = RightsManager.publisher_list(infos).map { |p| PublishersDb.resolve_contact(p["ipi"])[1] || p }.uniq
    candidates = contacts.select { |p| p["email"].to_s.strip.empty? && !p["address"].to_s.strip.empty? }
    return puts error("👎 aucun éditeur sans email (avec adresse) pour cette chanson") if candidates.empty?

    publisher = candidates.size == 1 ? candidates.first : choose_postal_publisher(prompt, candidates)
    return unless publisher

    kind = RightsManager.rights_status(infos) == "none" ? :first_contact : :relance
    letter = postal_letter_text(infos, publisher, kind)

    base_dir = File.join(folder, POSTAL_DIR_NAME)
    kind_dir = File.join(base_dir, kind == :first_contact ? "premier contact" : "relance")
    FileUtils.mkdir_p(kind_dir)
    File.write(File.join(kind_dir, "lettre.txt"), letter)
    address_lines = publisher["address"].to_s.split(",").map(&:strip).reject(&:empty?)
    File.write(File.join(base_dir, "adresse.txt"), ([publisher["name"]] + address_lines).join("\n") + "\n")

    system("open", folder)
    puts success("👍 lettre et adresse créées, dossier ouvert")

    system("open", POSTAL_SITE_URL) if prompt.yes?(yellow("Ouvrir le site d'envoi de courrier en ligne de La Poste ?"))

    return unless prompt.yes?(yellow("Dois-je marquer que la demande d'autorisation a été transmise ?"), default: true)

    event = kind == :first_contact ? "demande envoyée par la poste (premier contact)" : "relance envoyée par la poste"
    new_status = kind == :first_contact ? "sent" : RightsManager.rights_status(infos)
    RightsManager.append_rights_status(infos_path, new_status, event)
    puts success("👍 statut mis à jour")
  rescue Interrupt
    puts
  end

  def self.choose_postal_publisher(prompt, candidates)
    choices = candidates.map { |p| { name: "#{p["name"]} — #{p["address"]}", value: p } }
    choices << { name: orange("Annuler"), value: nil }
    prompt.select(yellow("Quel éditeur ?"), choices, show_help: false, per_page: choices.size)
  end

  def self.postal_letter_text(infos, publisher, kind)
    song = {
      title: infos["title"].to_s, performer: infos["performer"].to_s, composer: infos["composer"].to_s,
      lyrics: infos["lyrics"].to_s, iswc: infos["iswc"].to_s,
    }
    group = RightsMailer::Group.new(publisher_name: publisher["name"], publisher_email: nil, songs: [song])
    msg = RightsMailer.build_message(group, kind)
    "#{msg[:body].gsub("{logo}", "").strip}\n"
  end

  def self.open_publishers_db
    path = PublishersDb.path
    File.write(path, "") unless File.exist?(path)
    system("open", "-a", AppConfig.user_song_editor, path)
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
      action_choices = [
        { name: all_none ? "Premier contact" : "Relance", value: all_none ? :first_contact : :relance },
        { name: all_none ? "Relance (statut déjà avancé ?)" : "Premier contact (forcer)", value: all_none ? :relance : :first_contact },
        { name: orange("Ignorer"), value: nil },
      ]
      action = prompt.select("  Action :", action_choices, show_help: false, per_page: action_choices.size)
      planned << [g, action] if action
    end
    return puts gray("Rien à envoyer.") if planned.empty?

    puts
    puts blue("#{planned.size} email(s) vont être envoyés :")
    planned.each { |g, kind| puts "  - #{g.publisher_email} (#{kind == :first_contact ? "premier contact" : "relance"})" }
    return puts gray("Annulé.") unless prompt.yes?(yellow("Confirmer l'envoi ?"))

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
