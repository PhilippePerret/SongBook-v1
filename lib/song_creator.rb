# frozen_string_literal: true

require "tty-prompt"
require "tty-spinner"
require "cgi"
require "net/http"
require "json"
require "rbconfig"
require_relative "carnet_builder"
require_relative "app_config"
require_relative "ansi_colors"
require_relative "locale"
require_relative "file_finder"

# `songbook create song` : wizard interactif (TTY::Prompt), étape par étape — le
# dossier/gabarit n'est créé qu'une fois TOUTES les informations réunies
# (`CarnetBuilder.create_song_files`, appelé en tout dernier).
module SongCreator
  def self.run(title = nil, performer = nil)
    prompt = TTY::Prompt.new

    title ||= prompt.ask("Titre de la chanson :") { |q| q.required true }
    performer ||= prompt.ask("Interprète :") { |q| q.required true }

    songs_dir = AppConfig.songs_dir
    existing = CarnetBuilder.find_song(songs_dir, title, performer)
    return handle_existing_song(prompt, existing) if existing

    folder_title = CarnetBuilder.move_article_to_end(title)

    year = ask_year(prompt, title, performer)
    id = CarnetBuilder.slugify("#{title} #{performer} #{year}")

    cl = find_composer_lyricist(title, performer)
    offer_wikipedia_page(prompt, cl, title, performer)
    composer = prompt.ask("Compositeur :", default: cl[:composer]) { |q| q.required true }
    lyricist = prompt.ask("Parolier :", default: cl[:lyricist]) { |q| q.required true }

    infos = {
      "id" => id,
      "title" => title,
      "performer" => performer,
      "composer" => composer,
      "lyrics" => lyricist,
      "year" => year,
      "transpose" => "",
    }

    lyr_content = fetch_lyrics(title, performer) || CarnetBuilder::SONG_TEMPLATE

    result = CarnetBuilder.create_song_files(songs_dir, folder_title, infos, lyr_content)

    editor = AppConfig.user_song_editor
    system("open", "-a", editor, result[:infos_path], result[:lyr_path])

    print_success(Loc.get("song_created"))
    offer_open_folder(prompt, result[:folder])
    result[:folder]
  end

  # Chanson déjà trouvée (`CarnetBuilder.find_song`) : poursuivre (compléter les champs
  # vides de la fiche existante) ou juste demander à ouvrir son dossier (même question/
  # mécanisme que `offer_open_folder`, appelée en fin de création normale).
  def self.handle_existing_song(prompt, folder)
    choice = prompt.select(format(Loc.get("song_exists"), folder), [
      { name: Loc.get("continue_creation"), value: :continue },
      { name: Loc.get("open_folder_question"), value: :open },
    ], show_help: false)
    case choice
    when :continue then resume_existing_song(prompt, folder)
    when :open then offer_open_folder(prompt, folder)
    end
  end

  # Ne complète QUE les champs vides de la fiche existante (year/composer/lyrics) — ne
  # touche jamais un champ déjà renseigné. Paroles : remplacées seulement si `c.lyr` est
  # encore le gabarit vide (`SONG_TEMPLATE`) tel quel, jamais si Phil a déjà écrit dedans.
  def self.resume_existing_song(prompt, folder)
    infos_path = FileFinder.find(folder, :inf) || File.join(folder, "c.infos")
    lyr_path = FileFinder.find(folder, :lyr) || File.join(folder, "c.lyr")
    infos = File.exist?(infos_path) ? CarnetBuilder.parse_nested_infos(infos_path) : {}

    title = infos["title"]
    performer = infos["performer"]

    infos["year"] = ask_year(prompt, title, performer) if infos["year"].to_s.strip.empty?

    cl = nil
    if infos["composer"].to_s.strip.empty? || infos["lyrics"].to_s.strip.empty?
      cl = find_composer_lyricist(title, performer)
      offer_wikipedia_page(prompt, cl, title, performer)
    end
    infos["composer"] = prompt.ask("Compositeur :", default: cl && cl[:composer]) { |q| q.required true } if infos["composer"].to_s.strip.empty?
    infos["lyrics"] = prompt.ask("Parolier :", default: cl && cl[:lyricist]) { |q| q.required true } if infos["lyrics"].to_s.strip.empty?

    File.write(infos_path, "#{infos.map { |k, v| "#{k}: #{v}" }.join("\n")}\n")

    lyr_text = File.exist?(lyr_path) ? File.read(lyr_path) : nil
    if lyr_text.nil? || lyr_text.strip == CarnetBuilder::SONG_TEMPLATE.strip
      fetched = fetch_lyrics(title, performer)
      File.write(lyr_path, fetched) if fetched
    end

    editor = AppConfig.user_song_editor
    system("open", "-a", editor, infos_path, lyr_path)

    print_success(Loc.get("song_updated"))
    offer_open_folder(prompt, folder)
    folder
  end

  def self.offer_open_folder(prompt, folder)
    return unless prompt.yes?(Loc.get("open_folder_question"))

    open_in_file_manager(folder)
  end

  def self.open_in_file_manager(folder)
    case RbConfig::CONFIG["host_os"]
    when /darwin/ then system("open", folder)
    when /mswin|mingw|cygwin/ then system("explorer", folder)
    else system("xdg-open", folder)
    end
  end

  SPINNER_COLOR = AnsiColors::BLUE
  SUCCESS_COLOR = AnsiColors::SUCCESS
  ANSI_RESET = AnsiColors::RESET

  def self.print_success(message)
    puts "#{SUCCESS_COLOR}👍 #{message}#{ANSI_RESET}"
  end

  # `clear: true` : le message disparaît entièrement (ligne effacée) une fois la recherche
  # terminée, ne reste rien à l'écran — pas un simple "Terminé" affiché après.
  def self.with_spinner(message)
    spinner = TTY::Spinner.new("#{SPINNER_COLOR}[:spinner] #{message}#{ANSI_RESET}", format: :dots, clear: true)
    spinner.auto_spin
    yield
  ensure
    spinner&.stop
  end

  YEAR_RE = /\b(1[6-9]\d{2}|20\d{2})\b/
  # "composée en", "sortie en", "produite en", "parue en", "publiée en", "créée en" 1968.
  CONTEXTUAL_YEAR_RE = /\b(?:compos[ée]e?|sorti[e]?|produit[e]?|parue?|publi[ée]e?|cr[ée][ée]e?)\s+en\s+(1[6-9]\d{2}|20\d{2})\b/i

  # Interroge les 3 sources, PAS en cascade "1re réponse gagne" — toutes consultées :
  # Discogs, MusicBrainz (chacune : année la plus ancienne parmi les sorties/enregistrements
  # correspondants), Wikipédia FR (contexte "sortie en"/"composée en"/... sur la page
  # entière, sinon 1re année plausible du texte en dernier recours). AllMusic exclu : pas
  # d'API publique, seul le scraping HTML serait possible (fragile, zone grise ToS) — pas
  # fait sans demande explicite.
  # 1 seule année distincte trouvée -> confiance, proposée en défaut à valider.
  # Plusieurs années DIFFÉRENTES trouvées -> pas de confiance, choix soumis à l'user
  # (`tty-prompt` select, chaque option annotée de sa/ses source(s)).
  # Rien trouvé -> demandée sans suggestion.
  def self.find_year_candidates(title, performer)
    with_spinner("Recherche en cours…") do
      candidates = []
      (y = discogs_year(title, performer)) && candidates << { source: "Discogs", year: y }
      (y = musicbrainz_year(title, performer)) && candidates << { source: "MusicBrainz", year: y }
      begin
        text = wikipedia_full_text(title, performer)
        if (y = text&.[](CONTEXTUAL_YEAR_RE, 1))
          candidates << { source: "Wikipédia (contexte)", year: y }
        elsif (y = text&.[](YEAR_RE, 1))
          candidates << { source: "Wikipédia (1re année du texte)", year: y }
        end
      rescue StandardError
        nil
      end
      candidates
    end
  end

  # Carnets de chant, pas une thèse (Phil) : 1 an d'écart entre sources = bruit (rééditions,
  # dates de dépôt légal différentes...), pas une vraie divergence — prendre la plus basse
  # SANS demander de choisir. Le select n'apparaît que si l'écart dépasse 1 an.
  def self.ask_year(prompt, title, performer)
    candidates = find_year_candidates(title, performer)
    by_year = candidates.group_by { |c| c[:year] }
    years = by_year.keys.map(&:to_i)

    if years.empty?
      prompt.ask("Année :") { |q| q.required true }
    elsif years.max - years.min <= 1
      prompt.ask("Année :", default: years.min.to_s) { |q| q.required true }
    else
      choices = by_year.map { |year, cs| { name: "#{year} (#{cs.map { |c| c[:source] }.join(", ")})", value: year } }
      choices << { name: "Autre (saisir)", value: :other }
      picked = prompt.select("Plusieurs années trouvées, laquelle ?", choices, show_help: false)
      picked == :other ? prompt.ask("Année :") { |q| q.required true } : picked
    end
  end

  def self.discogs_year(title, performer)
    uri = URI("https://api.discogs.com/database/search")
    uri.query = URI.encode_www_form(q: "#{title} #{performer}", type: "release", per_page: 50)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "SongBook-app/1.0 (recherche année de sortie)"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |http| http.request(req) }
    data = JSON.parse(res.body)
    years = (data["results"] || []).map { |r| r["year"] }.compact.reject(&:empty?).map(&:to_i).reject(&:zero?)
    years.min&.to_s
  rescue StandardError
    nil
  end

  def self.musicbrainz_year(title, performer)
    data = musicbrainz_get("recording/", query: %(recording:"#{title}" AND artist:"#{performer}"), fmt: "json", limit: 100)
    years = (data["recordings"] || []).map { |r| r["first-release-date"] }.compact.map { |d| d[0, 4].to_i }.reject(&:zero?)
    years.min&.to_s
  rescue StandardError
    nil
  end

  # 2 sources, la 1re trouvée pour chaque champ gagne (pas de comparaison, contrairement à
  # l'année — un nom de personne ne se "moyenne" pas) :
  # 1. Wikipédia FR, infobox de l'article (wikitexte brut, `| compositeur =`/`| musique =`/
  #    `| parolier =`/`| paroles =`/`| auteur =`/`| auteur-compositeur =` — ce dernier sert
  #    aux deux champs) : testé fiable ("(I Can't Get No) Satisfaction" -> Jagger/Richards
  #    via `auteur-compositeur`).
  # 2. MusicBrainz (relations d'œuvre recording -> work -> artist-rels, type "composer"/
  #    "lyricist") : testé fiable ("À bicyclette" -> Francis Lai/Pierre Barouh).
  def self.find_composer_lyricist(title, performer)
    with_spinner("Recherche en cours…") do
      wiki = wikipedia_composer_lyricist(title, performer)
      mb = (wiki[:composer] && wiki[:lyricist]) ? { composer: nil, lyricist: nil } : musicbrainz_composer_lyricist(title, performer)
      { composer: wiki[:composer] || mb[:composer], lyricist: wiki[:lyricist] || mb[:lyricist], wikipedia_pageid: wiki[:pageid] }
    end
  end

  # Compositeur et/ou parolier introuvables : demande (message localisé) avant d'ouvrir
  # la fiche Wikipédia — page trouvée si `wikipedia_pageid` connu, sinon recherche.
  def self.offer_wikipedia_page(prompt, cl, title, performer)
    missing = []
    missing << Loc.get("composer") if cl[:composer].nil?
    missing << Loc.get("lyrics") if cl[:lyricist].nil?
    return if missing.empty?

    items = missing.map { |f| format(Loc.get("wiki_missing_item"), f) }.join(" #{Loc.get('wiki_missing_join')} ")
    return unless prompt.yes?(format(Loc.get("ask_open_wikipedia"), items))

    url = cl[:wikipedia_pageid] ? "https://fr.wikipedia.org/?curid=#{cl[:wikipedia_pageid]}" : "https://fr.wikipedia.org/w/index.php?search=#{CGI.escape("#{title} #{performer}")}"
    system("open", url)
  end

  def self.musicbrainz_composer_lyricist(title, performer)
    recording_id = musicbrainz_get("recording/", query: %(recording:"#{title}" AND artist:"#{performer}"), fmt: "json", limit: 1)
      .dig("recordings", 0, "id")
    return { composer: nil, lyricist: nil } unless recording_id

    work_id = musicbrainz_get("recording/#{recording_id}", inc: "work-rels", fmt: "json")["relations"]
      &.find { |r| r["target-type"] == "work" }&.dig("work", "id")
    return { composer: nil, lyricist: nil } unless work_id

    relations = musicbrainz_get("work/#{work_id}", inc: "artist-rels", fmt: "json")["relations"] || []
    {
      composer: relations.find { |r| r["type"] == "composer" }&.dig("artist", "name"),
      lyricist: relations.find { |r| r["type"] == "lyricist" }&.dig("artist", "name"),
    }
  rescue StandardError
    { composer: nil, lyricist: nil }
  end

  def self.wikipedia_composer_lyricist(title, performer)
    pageid = wikipedia_search_pageid("#{title} #{performer} chanson")
    return { composer: nil, lyricist: nil, pageid: nil } unless pageid

    wikitext = wikipedia_wikitext(pageid)
    return { composer: nil, lyricist: nil, pageid: pageid } unless wikitext

    combined = wikipedia_infobox_field(wikitext, %w[auteur-compositeur])
    composer = wikipedia_infobox_field(wikitext, %w[compositeur musique]) || combined
    lyricist = wikipedia_infobox_field(wikitext, %w[parolier paroles auteur]) || combined
    { composer: clean_wikitext(composer), lyricist: clean_wikitext(lyricist), pageid: pageid }
  rescue StandardError
    { composer: nil, lyricist: nil, pageid: nil }
  end

  def self.wikipedia_infobox_field(wikitext, field_names)
    re = /\A\s*\|\s*(?:#{field_names.join("|")})\s*=\s*(.+?)\s*\z/i
    wikitext.each_line.map { |l| l[re, 1] }.compact.first
  end

  # "[[Mick Jagger|Jagger]], [[Keith Richards|Richards]]" -> "Jagger, Richards" — retire
  # les liens/templates wikitexte, garde le texte affiché.
  def self.clean_wikitext(raw)
    return nil unless raw

    text = raw.gsub(/\{\{[^{}]*\}\}/, "")
      .gsub(/\[\[[^\]|]*\|([^\]]*)\]\]/, '\1')
      .gsub(/\[\[([^\]]*)\]\]/, '\1')
      .strip
    text.empty? ? nil : text
  end

  # MusicBrainz impose ~1 requête/s (limite constatée : appels rapprochés -> 503,
  # avalés par le `rescue StandardError` des appelants -> faux négatifs silencieux,
  # ex. compositeur/parolier de "Bohemian Rhapsody" jamais trouvés en pratique).
  MUSICBRAINZ_MIN_INTERVAL = 1.1

  # `api.lyrics.ovh` (gratuite, pas de clé) — texte brut, paragraphes séparés par une
  # ligne vide : format déjà valide pour `.lyr` (`parse_lyr` nomme "couplet-N" tout
  # paragraphe sans `{nom}`, voir `page_builder.rb`), pas de retouche nécessaire.
  # `nil` si la chanson n'y est pas (gabarit vide, `SONG_TEMPLATE`, utilisé à la place).
  def self.fetch_lyrics(title, performer)
    with_spinner("Recherche en cours…") do
      uri = URI("https://api.lyrics.ovh/v1/#{CGI.escape(performer)}/#{CGI.escape(title)}")
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) { |http| http.get(uri) }
      next nil unless res.is_a?(Net::HTTPSuccess)

      text = JSON.parse(res.body)["lyrics"]&.strip
      text.to_s.empty? ? nil : "#{text}\n"
    end
  rescue StandardError
    nil
  end

  def self.musicbrainz_get(path, params)
    wait = MUSICBRAINZ_MIN_INTERVAL - (Time.now - (@musicbrainz_last_call_at || Time.at(0)))
    sleep(wait) if wait.positive?
    uri = URI("https://musicbrainz.org/ws/2/#{path}")
    uri.query = URI.encode_www_form(params)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "SongBook-app/1.0 (songbook create song)"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |http| http.request(req) }
    @musicbrainz_last_call_at = Time.now
    JSON.parse(res.body)
  end

  def self.wikipedia_full_text(title, performer)
    pageid = wikipedia_search_pageid("#{title} #{performer} chanson")
    pageid && wikipedia_extract(pageid)
  end

  def self.wikipedia_get(params)
    uri = URI("https://fr.wikipedia.org/w/api.php")
    uri.query = URI.encode_www_form(params)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
      JSON.parse(http.get(uri).body)
    end
  end

  def self.wikipedia_search_pageid(query)
    data = wikipedia_get(action: "query", list: "search", srsearch: query, format: "json")
    data.dig("query", "search", 0, "pageid")
  end

  # `exintro` retiré (Phil : la mention "sortie en..." est rarement dans le 1er
  # paragraphe) — texte entier de la page.
  def self.wikipedia_extract(pageid)
    data = wikipedia_get(action: "query", prop: "extracts", explaintext: true, pageids: pageid, format: "json")
    data.dig("query", "pages", pageid.to_s, "extract")
  end

  # Wikitexte brut (pas le texte affiché) : seul format où l'infobox ("| compositeur = ...")
  # est parcourable — `extracts` (utilisé pour l'année) rend le texte affiché, sans elle.
  def self.wikipedia_wikitext(pageid)
    data = wikipedia_get(action: "query", pageids: pageid, prop: "revisions", rvprop: "content", rvslots: "main", format: "json")
    data.dig("query", "pages", pageid.to_s, "revisions", 0, "slots", "main", "*")
  end
end
