# frozen_string_literal: true

require "date"
require_relative "sacem_client"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "app_config"

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

  Result = Struct.new(:folder, :title, :status, :message, keyword_init: true)

  # `status` possibles : `:ok` (music_publisher écrit), `:skipped` (déjà renseigné,
  # `force:` non demandé), `:not_found` (0 résultat Sacem), `:ambiguous` (plusieurs
  # résultats Sacem avec des éditeurs DIFFÉRENTS — jamais choisi au hasard, "tu ne
  # devines RIEN"), `:error` (pas de `.infos`/pas de titre).
  def self.process_song(client, song_folder, force: false)
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

    title = infos["title"].to_s.strip
    return Result.new(folder: song_folder, title: title_label, status: :error,
                       message: "pas de `title` dans le .infos — recherche impossible") if title.empty?

    creator = [infos["composer"], infos["lyrics"], infos["performer"]].map(&:to_s).map(&:strip).find { |v| !v.empty? }.to_s

    items = client.search(title, creator)

    if items.empty?
      return Result.new(folder: song_folder, title: title_label, status: :not_found, message:
        "aucun résultat Sacem pour titre=\"#{title}\" / créateur=\"#{creator}\" — " \
        "ACTION : vérifier l'orthographe du titre/compositeur dans le .infos, ou chercher " \
        "à la main sur repertoire.sacem.fr (peut-être enregistrée sous un autre titre)")
    end

    editors = items.map { |it| editor_of(it) }.reject { |e| e.to_s.strip.empty? }.map { |e| e.upcase }.uniq

    if items.size > 1 && editors.size > 1
      summary = items.each_with_index.map { |it, i| "##{i + 1} #{it["title"]} — #{editor_of(it) || "éditeur inconnu"}" }.join(" | ")
      return Result.new(folder: song_folder, title: title_label, status: :ambiguous, message:
        "#{items.size} résultats Sacem avec des éditeurs DIFFÉRENTS (#{summary}) — " \
        "ACTION : ouvrir repertoire.sacem.fr, chercher titre=\"#{title}\" / créateur=\"#{creator}\", " \
        "choisir la bonne fiche, puis compléter music_publisher à la main dans le .infos")
    end

    detail = client.fetch_detail(items.first["href"])
    publisher = detail["publisher"]

    if !publisher || publisher["name"].to_s.strip.empty?
      return Result.new(folder: song_folder, title: title_label, status: :ambiguous, message:
        "résultat Sacem trouvé mais fiche éditeur illisible sur la page détail — " \
        "ACTION : vérifier à la main #{SacemClient::BASE_URL}#{items.first["href"]}")
    end

    note_parts = []
    note_parts << "#{items.size} fiches Sacem concordantes (même éditeur)" if items.size > 1
    note_parts << "adresse/email non publiés par la Sacem pour cette fiche" if publisher["address"].to_s.empty? && publisher["email"].to_s.empty?

    fields = {
      name: publisher["name"],
      email: publisher["email"],
      address: publisher["address"],
      site_url: nil,
      # `role` (Editeur/Sous Editeur) et `ipi` : identifient l'ÉDITEUR (le `ipi` d'une
      # maison d'édition ne change jamais, contrairement au nom — parfois retapé
      # différemment d'une fiche à l'autre) — `checked_at` : Phil, 2026-09-22, "il
      # faudrait dater ces données" (un éditeur/sous-éditeur peut changer avec le temps,
      # contrairement à l'ISWC de l'œuvre — voir plus bas).
      role: publisher["label"],
      ipi: publisher["ipi"],
      checked_at: Date.today.iso8601,
      note: note_parts.compact.join(" ; "),
    }

    # `iswc` : identifie l'ŒUVRE elle-même (immuable, indépendant de qui l'édite
    # aujourd'hui) -> propriété de la CHANSON, à la racine du .infos, PAS dans
    # `music_publisher` (Phil, 2026-09-22, "on peut faire des champs pour ce numéro").
    existing_iswc = infos["iswc"].to_s.strip
    if (force || existing_iswc.empty?) && !detail["iswc"].to_s.strip.empty?
      write_top_level_scalar(infos_path, "iswc", detail["iswc"])
    end

    write_nested_block(infos_path, "music_publisher", fields)

    Result.new(folder: song_folder, title: title_label, status: :ok, message: publisher["name"])
  end

  def self.editor_of(item)
    item["fields"]["Editeur"] || item["fields"]["Sous Editeur"]
  end

  # --- Suivi d'une demande de droits (statut + historique daté) -----------------------

  # Le format `.infos` (pseudo YAML maison, `CarnetBuilder.parse_nested_infos`) ne
  # supporte PAS les listes (`- item`) — l'historique est donc un bloc imbriqué à clés
  # numériques ("1", "2"...), chaque valeur étant "AAAA-MM-JJ : texte" (Phil, 2026-09-22,
  # a validé ce compromis faute de mieux dans ce format).
  def self.append_rights_status(infos_path, status, event_text)
    raise ArgumentError, "statut inconnu : #{status}" unless STATUSES.include?(status.to_s)

    infos = CarnetBuilder.parse_nested_infos(infos_path)
    rights = infos["reproduction_rights"].is_a?(Hash) ? infos["reproduction_rights"] : {}
    history = rights["history"].is_a?(Hash) ? rights["history"].dup : {}
    next_key = history.keys.map { |k| k.to_s.to_i }.max.to_i + 1
    history[next_key.to_s] = "#{Date.today.iso8601} : #{event_text}"

    write_nested_block(infos_path, "reproduction_rights", { "status" => status, "history" => history })
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

  def self.append_log(results)
    File.open(log_path, "a") do |f|
      f.puts "=== #{Time.now} ==="
      results.each { |r| f.puts "[#{r.status}] #{r.title} (#{File.basename(r.folder)}) — #{r.message}" }
    end
  end
end
