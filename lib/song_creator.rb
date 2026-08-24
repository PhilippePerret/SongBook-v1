# frozen_string_literal: true

require "tty-prompt"
require "tty-spinner"
require "cgi"
require "net/http"
require "json"
require_relative "carnet_builder"
require_relative "app_config"

# `songbook create song` : wizard interactif (TTY::Prompt), étape par étape — le
# dossier/gabarit n'est créé qu'une fois TOUTES les informations réunies
# (`CarnetBuilder.create_song_files`, appelé en tout dernier).
module SongCreator
  def self.run(title = nil, performer = nil)
    prompt = TTY::Prompt.new

    title ||= prompt.ask("Titre de la chanson :") { |q| q.required true }
    performer ||= prompt.ask("Interprète :") { |q| q.required true }

    folder_title = CarnetBuilder.move_article_to_end(title)

    search_song_info(title, performer)

    year = ask_year(prompt, title, performer)
    id = CarnetBuilder.slugify("#{title} #{performer} #{year}")

    cl = find_composer_lyricist(title, performer)
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

    songs_dir = AppConfig.songs_dir
    result = CarnetBuilder.create_song_files(songs_dir, folder_title, infos, lyr_content)

    editor = AppConfig.user_song_editor
    system("open", "-a", editor, result[:infos_path], result[:lyr_path])

    result[:folder]
  end

  # `clear: true` : le message disparaît entièrement (ligne effacée) une fois la recherche
  # terminée, ne reste rien à l'écran — pas un simple "Terminé" affiché après.
  def self.with_spinner(message)
    spinner = TTY::Spinner.new("[:spinner] #{message}", format: :dots, clear: true)
    spinner.auto_spin
    yield
  ensure
    spinner&.stop
  end

  # Ouvre une recherche web (comme `DiagsPage.build_and_open!`, `system("open", ...)`) —
  # Phil lit les résultats, l'année/le compositeur/le parolier proposés ensuite sont
  # toujours soumis à SA validation.
  def self.search_song_info(title, performer)
    query = "#{title} #{performer} chanson paroles musique wiki"
    url = "https://www.google.com/search?q=#{CGI.escape(query)}"
    system("open", url)
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
      prompt.ask("Année (non trouvée sur le net) :") { |q| q.required true }
    elsif years.max - years.min <= 1
      year = years.min.to_s
      sources = candidates.map { |c| c[:source] }.uniq.join(", ")
      prompt.ask("Année (trouvée avec assurance, #{sources}) :", default: year) { |q| q.required true }
    else
      choices = by_year.map { |year, cs| { name: "#{year} (#{cs.map { |c| c[:source] }.join(", ")})", value: year } }
      choices << { name: "Autre (saisir)", value: :other }
      picked = prompt.select("Plusieurs années trouvées, laquelle ?", choices)
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

  # Pas trouvé via un texte parcouru au hasard (Discogs/Wikipédia n'ont pas cette info
  # structurée) : relations d'œuvre MusicBrainz — recording -> work -> artist-rels
  # (type "composer"/"lyricist"), testé fiable ("À bicyclette" -> Francis Lai/Pierre
  # Barouh, exact). `nil`/`nil` si la chanson n'a pas de fiche `work` sur MusicBrainz.
  def self.find_composer_lyricist(title, performer)
    with_spinner("Recherche en cours…") do
      recording_id = musicbrainz_get("recording/", query: %(recording:"#{title}" AND artist:"#{performer}"), fmt: "json", limit: 1)
        .dig("recordings", 0, "id")
      next { composer: nil, lyricist: nil } unless recording_id

      work_id = musicbrainz_get("recording/#{recording_id}", inc: "work-rels", fmt: "json")["relations"]
        &.find { |r| r["target-type"] == "work" }&.dig("work", "id")
      next { composer: nil, lyricist: nil } unless work_id

      relations = musicbrainz_get("work/#{work_id}", inc: "artist-rels", fmt: "json")["relations"] || []
      {
        composer: relations.find { |r| r["type"] == "composer" }&.dig("artist", "name"),
        lyricist: relations.find { |r| r["type"] == "lyricist" }&.dig("artist", "name"),
      }
    end
  rescue StandardError
    { composer: nil, lyricist: nil }
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
end
