# frozen_string_literal: true

require "date"
require "set"
require "uri"
require_relative "sacem_client"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "app_config"
require_relative "publishers_db"

# Recherche l'éditeur ACTUEL (celui à contacter aujourd'hui pour négocier des droits,
# PAS l'éditeur d'origine s'il a changé) d'une chanson via `SacemClient`, et consigne le
# résultat dans la propriété `music_publisher` de son `.infos`/`.inf`
# (`name`/`email`/`address`/`site_url`/`ipi`/`role`/`checked_at`/`note`), plus `iswc` à la
# racine du `.infos` (identifie l'ŒUVRE, indépendamment de l'éditeur du moment). Gère
# aussi le suivi d'une demande de droits (`rights_status`/`rights_history`, voir
# `RightsMailer`). Par défaut : n'écrase JAMAIS un `music_publisher` déjà renseigné, et
# ne relance même pas la recherche pour lui (Phil, 2026-09-22, "on n'écrase pas, on ne
# recherche même pas sauf demande explicite") — voir `force:`.
module RightsManager
  LOG_FILE_NAME = ".rights_search.log"

  # Ordre "logique" d'avancement d'une demande — `refused` est une branche terminale à
  # part, pas une étape de la progression normale (Phil, 2026-09-22).
  STATUSES = %w[none sent negotiating authorized contract_signed refused].freeze

  # Étapes déjà atteintes par une chanson, en bits — indépendant du statut ACTUEL (qui
  # peut redescendre suite à une correction manuelle) : un bit, une fois posé, reste posé
  # (Phil, 2026-09-23, "Contrat signé ne doit pas être accessible si sent et negotiating
  # ne sont pas faits" — un statut n'est proposable que si TOUS ses prérequis ont déjà
  # été atteints au moins une fois). "none"/"refused" hors de cette progression linéaire.
  STAGE_BITS = { "sent" => 0b0001, "negotiating" => 0b0010, "authorized" => 0b0100, "contract_signed" => 0b1000 }.freeze
  STAGE_ORDER = %w[sent negotiating authorized contract_signed].freeze

  # `candidates` : présent seulement pour `:ambiguous` (les items Sacem bruts trouvés,
  # pour permettre de les revoir/choisir ensuite — voir `resolve_ambiguous!` et
  # `RightsCli.review_ambiguous`).
  Result = Struct.new(:folder, :title, :status, :message, :candidates, keyword_init: true)

  # `status` possibles : `:ok` (music_publisher écrit), `:skipped` (déjà renseigné,
  # `force:` non demandé), `:not_found` (0 résultat Sacem), `:ambiguous` (plusieurs
  # résultats Sacem avec des éditeurs DIFFÉRENTS — jamais choisi au hasard, "tu ne
  # devines RIEN"), `:error` (pas de `.infos`/pas de titre).
  # `search_title:` — cherche sous CE titre au lieu de `infos["title"]` (Phil,
  # 2026-09-22, "je puisse dire de quelle chanson il s'agit" — le titre affiché dans le
  # carnet n'est pas toujours celui sous lequel la Sacem a enregistré l'œuvre) : sert
  # UNIQUEMENT à la recherche, n'écrase jamais `title:` dans le `.infos`.
  def self.process_song(client, song_folder, force: false, search_title: nil)
    infos_path = FileFinder.find(song_folder, :inf)
    title_label = File.basename(song_folder)
    return Result.new(folder: song_folder, title: title_label, status: :error,
                       message: "pas de fichier .infos/.inf dans ce dossier") unless infos_path

    infos = CarnetBuilder.parse_nested_infos(infos_path)
    title_label = infos["title"].to_s.strip.empty? ? title_label : infos["title"]

    existing = infos["music_publisher"]
    if !force && existing.is_a?(Hash) && !existing.empty?
      return Result.new(folder: song_folder, title: title_label, status: :skipped,
                         message: "music_publisher déjà renseigné (#{existing["name"]})")
    end

    title = (search_title || infos["title"]).to_s.strip
    return Result.new(folder: song_folder, title: title_label, status: :error,
                       message: "pas de `title` dans le .infos — recherche impossible") if title.empty?

    composer = infos["composer"].to_s
    lyricist = infos["lyrics"].to_s
    performer = infos["performer"].to_s

    # Essaie compositeur, PUIS parolier, PUIS interprète — jamais un seul (Phil,
    # 2026-09-22, bug constaté : "Armstrong"+compositeur "L. Armstrong" -> résultats
    # hors sujet (plein d'autres "Armstrong" sans rapport), alors que "Armstrong"+parolier
    # "Nougaro" trouve la bonne fiche direct, sans ambiguïté).
    creator_candidates = [composer, lyricist, performer].map(&:strip).reject(&:empty?).uniq
    creator_candidates = [""] if creator_candidates.empty?

    # ET essaie le titre AVEC l'apostrophe, PUIS SANS (remplacée par une espace) — Sacem
    # l'efface parfois complètement au lieu de la garder (Phil, 2026-09-22, bug
    # constaté : "C'est écrit" introuvable tel quel, "C EST ECRIT" — espace, aucune
    # apostrophe — trouve la vraie fiche, avec le bon compositeur).
    title_candidates = title_variants(title)
    known_names = [composer, lyricist].map(&:strip).reject(&:empty?)

    # S'arrête au premier essai (titre × créateur) qui ramène un résultat au bon titre
    # ET au bon compositeur/parolier connu — jamais juste "un titre qui matche" (bug
    # constaté : titre="C'est écrit"+compositeur brut "M. Françoise & R. Secco" -> 10
    # fiches "C'est écrit" SANS AUCUN rapport avec Secco, la boucle s'arrêtait quand
    # même dessus avant d'avoir essayé la variante "espace" qui, elle, trouve la bonne).
    # Sans nom connu (`known_names` vide) : le titre seul suffit, comme avant.
    creator = creator_candidates.first
    used_title = title
    items = []
    title_candidates.each do |t|
      creator_candidates.each do |c|
        found = client.search(t, c)
        creator = c
        used_title = t
        items = found
        break if good_title_matches(found, t, known_names).any?
      end
      break if good_title_matches(items, used_title, known_names).any?
    end
    title = used_title

    if items.empty?
      return Result.new(folder: song_folder, title: title_label, status: :not_found, message:
        "aucun résultat Sacem pour titre=\"#{title}\" / créateur=\"#{creator}\" — " \
        "ACTION : vérifier l'orthographe du titre/compositeur dans le .infos, ou chercher " \
        "à la main sur repertoire.sacem.fr (peut-être enregistrée sous un autre titre)")
    end

    # Filtre par compositeur/parolier CONNUS (Phil, 2026-09-22, "chercher aussi avec les
    # infos qu'on a, le compositeur et le parolier, ça évitera d'avoir des listes qui
    # grossissent indéfiniment") : filet de sécurité en plus de l'essai par créateur
    # ci-dessus — repli sur la liste non filtrée si le filtre éliminerait tout.
    known_names = [composer, lyricist].map(&:strip).reject(&:empty?)
    if known_names.any?
      by_creator = items.select { |it| creator_matches?(it, known_names) }
      items = by_creator unless by_creator.empty?
    end

    # Filtre sur le TITRE avant de juger de l'ambiguïté (Phil, 2026-09-22 : "pourquoi
    # proposes-tu les éditeurs d'un titre non recherché" — le moteur Sacem renvoie
    # aussi des variantes/titres approchants, ex. "LADY MADONNA LOVE VERSION" pour
    # "Lady Madonna" : jamais des candidats valables pour CETTE chanson). Aucun résultat
    # au bon titre du tout -> `:not_found` (jamais deviné sur un titre différent).
    matching = items.select { |it| titles_match?(it["title"], title) }
    if matching.empty?
      others = items.map { |it| it["title"] }.uniq.join(", ")
      return Result.new(folder: song_folder, title: title_label, status: :not_found, message:
        "aucun résultat Sacem au titre exact \"#{title}\" (Sacem propose d'autres titres : #{others}) — " \
        "ACTION : vérifier l'orthographe du titre dans le .infos, ou chercher à la main sur repertoire.sacem.fr")
    end

    # "Éditeur inconnu" n'est jamais un choix utile — retiré avant de juger de
    # l'ambiguïté, sauf si c'est VRAIMENT tout ce qu'il y a (Phil, 2026-09-22).
    known = matching.reject { |it| unknown_editor?(editor_of(it)) }
    usable = known.empty? ? matching : known

    resolved = reduce_by_superset(usable) { |it| editor_of(it) }
    superset_idx = resolved.size == 1 && usable.size > 1

    editors = resolved.map { |it| editor_of(it) }.reject { |e| e.to_s.strip.empty? }.map { |e| e.upcase }.uniq

    if resolved.size > 1 && editors.size > 1
      summary = resolved.each_with_index.map { |it, i| "##{i + 1} #{it["title"]} — #{editor_of(it) || "éditeur inconnu"}" }.join(" | ")
      return Result.new(folder: song_folder, title: title_label, status: :ambiguous, candidates: resolved, message:
        "#{resolved.size} résultats Sacem au bon titre avec des éditeurs DIFFÉRENTS (#{summary}) — " \
        "ACTION : ouvrir repertoire.sacem.fr, chercher titre=\"#{title}\" / créateur=\"#{creator}\", " \
        "choisir la bonne fiche, puis compléter music_publisher à la main dans le .infos")
    end

    detail = client.fetch_detail(resolved.first["href"])
    publishers = detail["publishers"]

    if publishers.nil? || publishers.empty?
      return Result.new(folder: song_folder, title: title_label, status: :ambiguous, candidates: resolved, message:
        "résultat Sacem trouvé mais fiche éditeur illisible sur la page détail — " \
        "ACTION : vérifier à la main #{SacemClient::BASE_URL}#{resolved.first["href"]}")
    end

    note = if superset_idx && matching.size > 1
             "éditeur le plus complet retenu parmi #{matching.size} fiches Sacem (les autres listaient un sous-ensemble de ces mêmes éditeurs)"
           elsif resolved.size > 1
             "#{resolved.size} fiches Sacem concordantes (même éditeur)"
           end
    write_publisher!(infos_path, infos, detail, extra_note: note, force: force)

    Result.new(folder: song_folder, title: title_label, status: :ok, message: publishers.map { |p| p["name"] }.join(" / "))
  end

  # Écrit l'éditeur d'une chanson à partir d'une fiche détail Sacem déjà récupérée
  # (`SacemClient#fetch_detail`, `detail["publishers"]` — UNE œuvre peut avoir PLUSIEURS
  # co-éditeurs, vérifié sur "Get Back" : Universal/Sony/Because sur la MÊME fiche, Phil
  # 2026-09-22). Les infos détaillées (name/email/address/role) vont dans `PublishersDb`,
  # PAS dans le `.infos` de la chanson — celle-ci ne garde que son/ses `ipi` (Phil,
  # 2026-09-23, "je gardais juste l'IPI et une base YAML avec toutes les infos") : évite
  # de dupliquer les mêmes coordonnées d'éditeur dans chaque chanson qu'il édite.
  # `publisher_key` sert de clé de fusion dans la base ET de valeur écrite dans `ipi`
  # (liste `" | "` si plusieurs éditeurs, comme les autres listes du projet).
  def self.write_publisher!(infos_path, infos, detail, extra_note: nil, force: false)
    publishers = detail["publishers"]
    checked_at = Date.today.iso8601

    keys = publishers.map do |p|
      key = publisher_key(p["ipi"], p["name"])
      PublishersDb.upsert!(key, {
        name: p["name"],
        email: valid_email?(p["email"]) ? p["email"] : nil,
        address: p["address"],
        role: p["role"],
        ipi: p["ipi"],
        note: p["note"],
        checked_at: checked_at,
      })
      key
    end

    # `iswc` : identifie l'ŒUVRE elle-même (immuable, indépendant de qui l'édite
    # aujourd'hui) -> propriété de la CHANSON, à la racine du .infos, PAS dans
    # `music_publisher` (Phil, 2026-09-22, "on peut faire des champs pour ce numéro").
    existing_iswc = infos["iswc"].to_s.strip
    if (force || existing_iswc.empty?) && !detail["iswc"].to_s.strip.empty?
      write_top_level_scalar(infos_path, "iswc", detail["iswc"])
    end

    block = { ipi: keys.join(" | "), checked_at: checked_at, note: extra_note }
    write_nested_block(infos_path, "music_publisher", block)
  end

  # Clé de `PublishersDb` pour un éditeur : son `ipi` (stable, jamais retapé
  # différemment d'une fiche à l'autre) — replié sur le nom slugifié SEULEMENT si Sacem
  # ne fournit aucun IPI (rare).
  def self.publisher_key(ipi, name)
    ipi.to_s.strip.empty? ? "sans-ipi-#{CarnetBuilder.slugify(name.to_s)}" : ipi.to_s.strip
  end

  # `infos["music_publisher"]["ipi"]` (liste `" | "`) -> tableau de hash
  # `{"name"=>, "email"=>, "address"=>, "role"=>, "ipi"=>}`, un par éditeur, lu depuis
  # `PublishersDb` (1 seul éditeur la plupart du temps).
  def self.publisher_list(infos)
    pub = infos["music_publisher"]
    return [] unless pub.is_a?(Hash) && !pub["ipi"].to_s.strip.empty?

    pub["ipi"].to_s.split(/\s*\|\s*/, -1).map do |key|
      entry = PublishersDb.find(key) || {}
      { "name" => entry["name"], "email" => entry["email"], "address" => entry["address"],
        "role" => entry["role"], "ipi" => entry["ipi"] || key }
    end
  end

  def self.valid_email?(text)
    text.to_s.strip.match?(URI::MailTo::EMAIL_REGEXP)
  end

  # Éditeur saisi à la main (Phil, 2026-09-23, "comment je fais pour entrer l'éditeur à
  # la main ?") : cas où la fiche Sacem est illisible (aucun co-éditeur, un seul
  # éditeur/infos). Écrit directement dans `PublishersDb`, sans passage par
  # `SacemClient#fetch_detail`.
  def self.write_publisher_manual!(infos_path, name:, ipi: nil, address: nil, email: nil, role: nil)
    checked_at = Date.today.iso8601
    key = publisher_key(ipi, name)
    PublishersDb.upsert!(key, {
      name: name, email: (valid_email?(email) ? email : nil), address: address, role: role, ipi: ipi,
      checked_at: checked_at,
    })
    write_nested_block(infos_path, "music_publisher", { ipi: key, checked_at: checked_at })
    key
  end

  def self.editor_of(item)
    item["fields"]["Editeur"] || item["fields"]["Sous Editeur"]
  end

  # `item` référence-t-il au moins UN des `known_names` (compositeur/parolier connus) ?
  # Comparé au NOM DE FAMILLE seul (dernier mot du nom connu) — les champs Sacem
  # ("Compositeur"/"Auteur"/"Compositeur-Auteur") sont en "NOM Prénom", jamais "Prénom
  # NOM" comme dans le `.infos` ("L. Armstrong" -> cherche juste "ARMSTRONG" dedans).
  def self.creator_matches?(item, known_names)
    fields_text = %w[Compositeur Auteur Compositeur-Auteur].map { |k| item["fields"][k] }.compact.join(" ").upcase
    known_names.any? { |n| fields_text.include?(surname_of(n).upcase) }
  end

  def self.surname_of(name)
    name.to_s.strip.split(/\s+/).last.to_s
  end

  # Comparaison de titres tolérante — réutilise `CarnetBuilder.slugify` (déjà dans le
  # projet, déjà éprouvé) qui neutralise en un coup accents ("ECRIT"/"écrit"), casse
  # et apostrophe (courbe/droite/absente, traitée comme séparateur de mot au même titre
  # qu'une espace) : "C'est écrit" / "C EST ECRIT" / "c est ecrit" slugifient tous vers
  # "c-est-ecrit" (Phil, 2026-09-22, bugs constatés successivement sur la casse, puis
  # l'apostrophe, puis l'accent — une seule comparaison robuste au lieu de rustines
  # empilées). Jamais utilisé pour la requête envoyée à Sacem, seulement pour juger si
  # un titre RENVOYÉ correspond au titre CHERCHÉ.
  def self.titles_match?(a, b)
    CarnetBuilder.slugify(a.to_s) == CarnetBuilder.slugify(b.to_s)
  end

  # Titre AVEC apostrophe (droite ou courbe) -> [titre tel quel, même titre avec
  # l'apostrophe remplacée par une espace] — Sacem enregistre parfois SANS aucune
  # apostrophe, à la place une espace pure ("C'est écrit" -> "C EST ECRIT" sur Sacem,
  # zéro apostrophe, vérifié). Titre sans apostrophe -> lui-même seul, rien à essayer
  # en plus.
  def self.title_variants(title)
    t = title.to_s.strip
    return [t] unless t.match?(/['’]/)

    space_variant = t.tr("’", "'").tr("'", " ").squeeze(" ").strip
    [t, space_variant].uniq
  end

  # Résultats de `items` dont le titre correspond à `title` ET (si `known_names` non
  # vide) dont le compositeur/parolier est reconnu — voir `process_song`, sert à décider
  # si un essai titre×créateur est "assez bon" pour arrêter d'en tenter d'autres.
  def self.good_title_matches(items, title, known_names)
    same_title = items.select { |it| titles_match?(it["title"], title) }
    return same_title if known_names.empty?

    same_title.select { |it| creator_matches?(it, known_names) }
  end

  # Sacem indique parfois lui-même qu'il ne connaît pas l'éditeur ("éditeur inconnu",
  # "INCONNU EDITEUR") — jamais un choix utile, jamais compté comme un vrai concurrent
  # dans une ambiguïté.
  def self.unknown_editor?(text)
    t = text.to_s.strip.downcase
    t.empty? || t.include?("inconnu")
  end

  # "Éditeur A" contre "Éditeur A et Éditeur B" n'est PAS une vraie ambiguïté (Phil,
  # 2026-09-22) : le 2e liste juste TOUS les éditeurs du 1er, plus un — jamais
  # contradictoire, juste plus complet. Réduit `items` au candidat unique dont les
  # éditeurs englobent ceux de TOUS les autres, s'il existe ; sinon `items` inchangé.
  # Utilisé par `process_song` (recherche live) ET `pending_ambiguous_from_log` (lecture
  # du log) — UNE seule règle, jamais dupliquée (bug constaté : la recherche live
  # l'appliquait, la revue depuis le log non, "je me retrouve avec [un faux choix]").
  # `editor_text` extrait le texte éditeur brut d'un item (forme différente selon
  # l'appelant : objet Sacem pour l'un, hash `{editor:}` pour l'autre).
  def self.reduce_by_superset(items, &editor_text)
    return items if items.size <= 1

    sets = items.map { |it| editor_text.call(it).to_s.split(/,\s*/).map { |e| e.strip.upcase }.reject(&:empty?).to_set }
    winner = sets.each_index.find { |i| sets.all? { |s| s.subset?(sets[i]) } }
    winner ? [items[winner]] : items
  end

  # L'user a choisi `item` (un des `candidates` d'un `Result` `:ambiguous`) — récupère sa
  # fiche détail et écrit `music_publisher` (Phil, 2026-09-22, "passer en revue les
  # ambiguïtés" : jamais choisi tout seul, toujours un choix explicite de l'user).
  # -> nom de l'éditeur écrit, ou `nil` si la fiche détail s'avère illisible.
  def self.resolve_ambiguous!(client, song_folder, item)
    infos_path = FileFinder.find(song_folder, :inf)
    return nil unless infos_path

    infos = CarnetBuilder.parse_nested_infos(infos_path)
    detail = client.fetch_detail(item["href"])
    publishers = detail["publishers"]
    return nil if publishers.nil? || publishers.empty?

    write_publisher!(infos_path, infos, detail, force: true)
    publishers.map { |p| p["name"] }.join(" / ")
  end

  LOG_AMBIGUOUS_RE = /\A\[ambiguous\] (.+?) \((.+?)\) — \d+ résultats Sacem.*?\((.+)\) — ACTION/.freeze

  # Parse UNE ligne `[ambiguous]` du log -> `{folder_name:, title:, candidates: [{index:,
  # title:, editor:}]}` — `candidates` vide pour le cas "fiche illisible" (pas de liste
  # numérotée dans le message, un seul résultat déjà connu mais indéchiffrable).
  def self.parse_log_ambiguous(line)
    m = line.match(LOG_AMBIGUOUS_RE)
    return nil unless m

    title, folder_name, candidates_text = m.captures
    candidates = candidates_text.split(" | ").filter_map do |c|
      idx, rest = c.match(/\A#(\d+)\s+(.+)\z/)&.captures
      next unless idx

      ctitle, editor = rest.split(" — ", 2)
      { index: idx.to_i, title: ctitle, editor: editor }
    end
    { folder_name: folder_name, title: title, candidates: candidates }
  end

  LOG_NOT_FOUND_TITLE_RE = /\A\[not_found\] (.+?) \((.+?)\) — aucun résultat Sacem au titre exact ".+?" \(Sacem propose d'autres titres : (.+?)\) — ACTION/.freeze

  # Parse UNE ligne `[not_found]` du log qui propose d'autres titres (Phil, 2026-09-22,
  # bug constaté : un `:not_found` avec titres alternatifs n'était JAMAIS repris par
  # "Passer en revue les ambiguïtés", qui ne lisait que les lignes `[ambiguous]` — le
  # correcteur de titre construit pour ce cas restait inatteignable) — même forme que
  # `parse_log_ambiguous` (`candidates` toujours vide ici, pas de fiche connue).
  def self.parse_log_not_found(line)
    m = line.match(LOG_NOT_FOUND_TITLE_RE)
    return nil unless m

    title, folder_name, others_text = m.captures
    { folder_name: folder_name, title: title, candidates: [], other_titles: others_text.split(", ").map(&:strip) }
  end

  # Ambiguïtés (+ titres non trouvés MAIS avec alternatives, voir `parse_log_not_found`)
  # encore en attente d'après le log (Phil, 2026-09-22, "Passer en revue les ambiguïtés" :
  # "les ambiguïtés doivent être relevées dans le fichier .log, pas rechercher à nouveau"
  # — la LISTE des candidats vient du log, texte déjà en main, AUCUNE recherche réseau
  # ici). Dernière occurrence par chanson gardée (log potentiellement ré-écrit plusieurs
  # fois) ; filtré sur l'état ACTUEL du `.infos` (jamais sur le log seul : un log périmé
  # si résolu autrement depuis).
  def self.pending_ambiguous_from_log
    return [] unless File.exist?(log_path)

    by_folder = {}
    File.readlines(log_path).each do |line|
      parsed = parse_log_ambiguous(line) || parse_log_not_found(line)
      by_folder[parsed[:folder_name]] = parsed if parsed
    end

    by_folder.values.filter_map do |entry|
      folder = File.join(AppConfig.songs_dir, entry[:folder_name])
      next unless Dir.exist?(folder)

      infos_path = FileFinder.find(folder, :inf)
      next unless infos_path

      publisher = CarnetBuilder.parse_nested_infos(infos_path)["music_publisher"]
      next if publisher.is_a?(Hash) && !publisher.empty?

      # D'anciennes lignes de log (avant le filtre par titre, Phil 2026-09-22) peuvent
      # encore contenir des candidats à titre différent ("LOVE VERSION"...) : jamais
      # proposés comme choix, retirés ici aussi, pas seulement à l'écriture du log.
      # `other_titles` gardé pour le message si ÇA vide toute la liste (Phil, 2026-09-22,
      # bug constaté : message "fiche illisible" affiché à tort — le vrai problème est
      # qu'aucun candidat n'a le titre exact, pas une fiche indéchiffrable).
      same_title = entry[:candidates].select { |c| titles_match?(c[:title], entry[:title]) }
      # `parse_log_not_found` fournit déjà ses propres `other_titles` (aucun candidat à
      # en dériver, `entry[:candidates]` toujours vide pour ce cas) — jamais écrasés.
      other_titles = entry[:other_titles] || (entry[:candidates] - same_title).map { |c| c[:title] }.uniq

      # "Éditeur inconnu"/"Inconnu éditeur" (Sacem lui-même ne sait pas) : jamais un choix
      # utile — retiré des options proposées, sauf si c'est VRAIMENT tout ce qui reste
      # (Phil, 2026-09-22, "'Éditeur inconnu' proposé comme un choix... inutile").
      known = same_title.reject { |c| unknown_editor?(c[:editor]) }
      usable = known.empty? ? same_title : known

      # MÊME règle "superset" que la recherche live (Phil, 2026-09-22, bug constaté :
      # "Éditeur A" / "Éditeur A+B" proposé comme un vrai choix en revue depuis le log,
      # alors que la recherche live l'aurait résolu tout seul) — réduit à 1 seul candidat
      # quand ça se résout tout seul, jamais un faux choix affiché.
      reduced = reduce_by_superset(usable) { |c| c[:editor] }
      entry.merge(folder: folder, candidates: reduced, other_titles: other_titles)
    end
  end

  # L'user a choisi le candidat `chosen_index` (position dans la liste du log) pour
  # `entry` — UNE SEULE recherche live, ici, pour CETTE chanson (jamais en amont sur
  # toutes les ambiguïtés à la fois) : nécessaire pour obtenir un lien réel vers la
  # fiche détail (les liens Sacem sont des tokens de session, jamais persistés dans le
  # log). Vérifie que le titre/éditeur retrouvés correspondent à ce qui était annoncé
  # par le log avant d'écrire — signale plutôt que d'écrire à l'aveugle si ça a bougé
  # depuis (répertoire Sacem mis à jour entretemps).
  def self.resolve_ambiguous_from_log!(client, entry, chosen_index)
    infos_path = FileFinder.find(entry[:folder], :inf)
    return { ok: false, message: "pas de fichier .infos/.inf" } unless infos_path

    infos = CarnetBuilder.parse_nested_infos(infos_path)
    title = infos["title"].to_s.strip
    creator = [infos["composer"], infos["lyrics"], infos["performer"]].map(&:to_s).map(&:strip).find { |v| !v.empty? }.to_s

    items = client.search(title, creator)
    chosen_item = items[chosen_index - 1]
    return { ok: false, message: "plus de #{chosen_index}e résultat Sacem pour cette chanson (le répertoire a changé)" } unless chosen_item

    expected = entry[:candidates].find { |c| c[:index] == chosen_index }
    drifted = expected && (editor_of(chosen_item).to_s.strip != expected[:editor].to_s.strip)

    detail = client.fetch_detail(chosen_item["href"])
    publishers = detail["publishers"]
    return { ok: false, message: "fiche détail illisible" } if publishers.nil? || publishers.empty?

    write_publisher!(infos_path, infos, detail, force: true)
    { ok: true, name: publishers.map { |p| p["name"] }.join(" / "), drifted: drifted }
  end

  # --- Suivi d'une demande de droits (statut + historique daté) -----------------------

  # Le format `.infos` n'a pas de syntaxe de liste native (`- item`) — mais contrairement
  # à `music_publisher` (champs à largeur fixe, un `" | "` par champ suffit, voir
  # `write_publisher!`), l'historique grandit sans fin et ses valeurs sont du texte libre
  # (pourrait contenir " | ") : bloc imbriqué à clés numériques ("1", "2"...) à la place,
  # chaque valeur étant "AAAA-MM-JJ : texte" (Phil, 2026-09-22, a validé ce compromis).
  # `extra:` (ex. `duration`/`start_date` à la signature d'un contrat, voir
  # `RightsExpiry`) fusionné PAR-DESSUS les clés déjà existantes du bloc (jamais perdues
  # au passage — un changement de statut ultérieur ne doit pas effacer la durée/date déjà
  # fixées).
  # `event_text` — `nil` pour un changement de statut qui n'est PAS un événement en soi
  # (Phil, 2026-09-23, "un changement manuel de statut n'est pas une action") : `history`
  # reste alors inchangé, seul `status`/`stages` avance.
  def self.append_rights_status(infos_path, status, event_text, extra: {})
    raise ArgumentError, "statut inconnu : #{status}" unless STATUSES.include?(status.to_s)

    infos = CarnetBuilder.parse_nested_infos(infos_path)
    rights = infos["reproduction_rights"].is_a?(Hash) ? infos["reproduction_rights"] : {}
    history = rights["history"].is_a?(Hash) ? rights["history"].dup : {}
    if event_text
      next_key = history.keys.map { |k| k.to_s.to_i }.max.to_i + 1
      history[next_key.to_s] = "#{Date.today.iso8601} : #{event_text}"
    end

    new_bits = rights["stages"].to_i | STAGE_BITS[status.to_s].to_i

    existing_extra = rights.reject { |k, _| %w[status history stages].include?(k) }
    block = { "status" => status, "history" => history, "stages" => new_bits }.merge(existing_extra).merge(extra.transform_keys(&:to_s))
    write_nested_block(infos_path, "reproduction_rights", block)
  end

  def self.rights_status(infos)
    status = infos.dig("reproduction_rights", "status").to_s
    STATUSES.include?(status) ? status : "none"
  end

  def self.rights_history(infos)
    history = infos.dig("reproduction_rights", "history")
    return [] unless history.is_a?(Hash)

    history.sort_by { |k, _| k.to_s.to_i }.map { |_, v| v.to_s }
  end

  # Bits explicitement enregistrés, complétés par ceux qu'implique le statut ACTUEL
  # (chansons déjà avancées avant l'introduction de ce système, jamais bloquées à tort).
  def self.stages_reached(infos)
    explicit = infos.dig("reproduction_rights", "stages").to_i
    status = rights_status(infos)
    idx = STAGE_ORDER.index(status)
    implied = idx.nil? ? 0 : STAGE_ORDER.first(idx + 1).sum { |s| STAGE_BITS[s] }
    explicit | implied
  end

  # `status` proposable pour cette chanson ? "none"/"refused" toujours (pas d'étape à
  # prouver) ; les autres seulement si TOUS les statuts qui les précèdent dans
  # `STAGE_ORDER` ont déjà été atteints au moins une fois.
  def self.status_selectable?(infos, status)
    return true unless STAGE_ORDER.include?(status.to_s)

    idx = STAGE_ORDER.index(status.to_s)
    required = idx.zero? ? 0 : STAGE_ORDER.first(idx).sum { |s| STAGE_BITS[s] }
    (stages_reached(infos) & required) == required
  end

  # --- Écriture bas niveau sur le .infos (préserve commentaires/mise en forme) --------

  # `.infos`/`.inf` : imbrication par indentation (`CarnetBuilder.parse_nested_infos`),
  # PAS du YAML — on manipule donc les LIGNES brutes plutôt que de reparser->resérialiser
  # tout l'arbre (perdrait les commentaires). Récursif : une valeur `Hash` s'écrit comme
  # un bloc enfant imbriqué (ex. `reproduction_rights: / status: / history: / 1: ...`),
  # pas seulement un niveau — nécessaire pour `reproduction_rights` (Phil, 2026-09-22).
  def self.write_nested_block(infos_path, key, fields)
    lines = File.exist?(infos_path) ? File.readlines(infos_path) : []
    lines = remove_top_level_block(lines, key)
    lines << "\n" unless lines.empty? || lines.last.to_s.strip.empty?
    lines.concat(serialize_block(key, fields, 0))
    File.write(infos_path, lines.join)
  end

  # Valeur vide -> le parseur maison l'interprète comme "ouvre un bloc enfant" (pas une
  # chaîne vide) : on OMET simplement les clés sans valeur trouvée plutôt que d'écrire
  # "clé: " (qui casserait la lecture par `parse_nested_infos`).
  def self.serialize_block(key, value, indent)
    pad = "  " * indent
    if value.is_a?(Hash)
      lines = ["#{pad}#{key}:\n"]
      value.each { |k, v| lines.concat(serialize_block(k, v, indent + 1)) }
      lines
    elsif value.to_s.strip.empty?
      []
    else
      ["#{pad}#{key}: #{value}\n"]
    end
  end

  def self.remove_top_level_block(lines, key)
    start = lines.find_index { |l| l.chomp.strip == "#{key}:" && l[/\A */].size.zero? }
    return lines unless start

    last_content = start
    i = start + 1
    while i < lines.length
      content = lines[i].chomp
      unless content.strip.empty?
        indent = content[/\A */].size
        break if indent.zero?

        last_content = i
      end
      i += 1
    end
    lines[0...start] + lines[(last_content + 1)..]
  end

  # Écrit/remplace une clé SCALAIRE à la racine (ex. `iswc:`, `rights_status:`) —
  # distinct de `write_nested_block` : ici une seule ligne, jamais de bloc enfant.
  def self.write_top_level_scalar(infos_path, key, value)
    lines = File.exist?(infos_path) ? File.readlines(infos_path) : []
    lines = lines.reject { |l| l.chomp.strip.start_with?("#{key}:") && l[/\A */].size.zero? }
    lines << "\n" unless lines.empty? || lines.last.to_s.strip.empty?
    lines << "#{key}: #{value}\n"
    File.write(infos_path, lines.join)
  end

  # Chemin du log détaillé (Phil, 2026-09-22 : "signalement clair des problèmes
  # (numérotés) en console + log détaillé") — un fichier par dossier de chansons, même
  # convention dotfile que `SongCache::CACHE_FILE`.
  def self.log_path
    File.join(AppConfig.songs_dir, LOG_FILE_NAME)
  end

  # Réécrit le log en entier à chaque appel (jamais d'accumulation, Phil, 2026-09-22,
  # "tu arrêtes de répéter mille fois le même message, une seule fois, les messages dont
  # on a besoin") : une ligne par chanson (la plus récente), et seulement les cas encore
  # À TRAITER — `:ok`/`:skipped` retirés du log (plus rien à faire dessus), fusionnés
  # avec ce qui reste d'un run précédent sur d'autres chansons.
  def self.append_log(results)
    existing = {}
    if File.exist?(log_path)
      File.readlines(log_path, chomp: true).each do |line|
        m = line.match(/\A\[\w+\] .+ \((.+)\)/)
        existing[m[1]] = line if m
      end
    end

    results.each do |r|
      key = File.basename(r.folder)
      if %i[ok skipped].include?(r.status)
        existing.delete(key)
      else
        existing[key] = "[#{r.status}] #{r.title} (#{key}) — #{r.message}"
      end
    end

    File.write(log_path, existing.values.map { |l| "#{l}\n" }.join)
  end
end
