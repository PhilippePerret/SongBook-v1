require "yaml"
require "rbconfig"
require_relative "ansi_colors"

# Configuration par défaut de l'application (Manuel/app/options.adoc) — `SongBook-app/config.yaml`,
# clé/valeur plates, chargé une seule fois. Un carnet surcharge via son `.infos`/`.inf`
# (ex. `front_matter.table_of_contents.position` surcharge `tdm_position`).
module AppConfig
  extend AnsiColors

  PATH = File.expand_path("../config.yaml", __dir__)

  CM_TO_PT = 72.0 / 2.54
  MM_TO_PT = CM_TO_PT / 10.0
  IN_TO_PT = 72.0

  def self.all
    @all ||= YAML.safe_load_file(PATH) || {}
  end

  def self.get(key)
    all[key.to_s]
  end

  # Écrit/remplace `key: value` dans config.yaml (met à jour la ligne existante, sinon
  # l'ajoute) — préserve le reste du fichier (commentaires compris), pas de réécriture YAML.
  def self.set(key, value)
    lines = File.exist?(PATH) ? File.readlines(PATH) : []
    idx = lines.index { |l| l.match?(/\A#{Regexp.escape(key.to_s)}\s*:/) }
    line = "#{key}: #{value}\n"
    idx ? (lines[idx] = line) : (lines << line)
    File.write(PATH, lines.join)
    @all = nil
    value
  end

  # Chemin absolu du dossier des chansons — demandé à l'user et enregistré dans
  # config.yaml au premier besoin si pas encore configuré.
  def self.songs_dir
    dir = get("songs_dir")
    return dir if dir && !dir.to_s.strip.empty? && Dir.exist?(dir.to_s)

    loop do
      print blue("Dossier des chansons : ")
      input = $stdin.gets.to_s.strip
      return set("songs_dir", input) if Dir.exist?(input)
      warn "dossier introuvable : #{input}"
    end
  end

  # Chemin absolu du dossier des carnets — même principe que `songs_dir` (demandé à
  # l'user et enregistré dans config.yaml au premier besoin si pas encore configuré).
  def self.songbooks_dir
    dir = get("songbooks_dir")
    return dir if dir && !dir.to_s.strip.empty? && Dir.exist?(dir.to_s)

    loop do
      print blue("Dossier des carnets : ")
      input = $stdin.gets.to_s.strip
      return set("songbooks_dir", input) if Dir.exist?(input)
      warn "dossier introuvable : #{input}"
    end
  end

  # Application (nom ou chemin, `open -a`) utilisée pour éditer les fichiers d'une
  # chanson (`c.infos`/`c.lyr`) — demandée à l'user et enregistrée au premier besoin.
  # Existence vérifiée (`editor_app?`) avant d'accepter, sinon reboucle.
  def self.user_song_editor
    app = get("user_song_editor")
    return app if app && editor_app?(app)

    loop do
      print blue("Éditer les chansons avec : ")
      input = $stdin.gets.to_s.strip
      return set("user_song_editor", input) if editor_app?(input)
      warn "application introuvable : #{input}"
    end
  end

  # macOS : `/Applications/<app>.app` (ou `~/Applications`). Windows : cherchée dans le
  # PATH (`where`). Un chemin direct fourni (fichier/dossier existant) est toujours
  # accepté tel quel. Autres OS : pas de vérification connue, accepté tel quel.
  def self.editor_app?(app)
    return false if app.to_s.strip.empty?
    return true if File.exist?(app)

    case RbConfig::CONFIG["host_os"]
    when /darwin/
      ["/Applications/#{app}.app", "/Applications/#{app}", File.expand_path("~/Applications/#{app}.app")].any? { |p| File.exist?(p) }
    when /mswin|mingw|cygwin/
      system("where", app, out: File::NULL, err: File::NULL)
    else
      true
    end
  end

  # "1cm" -> 28.35, "10mm" -> 28.35, "0.5in" -> 36.0, "12pt" -> 12.0, "12" -> 12.0.
  def self.length_pt(value)
    case value.to_s.strip
    when /\A([\d.]+)\s*cm\z/ then $1.to_f * CM_TO_PT
    when /\A([\d.]+)\s*mm\z/ then $1.to_f * MM_TO_PT
    when /\A([\d.]+)\s*in\z/ then $1.to_f * IN_TO_PT
    when /\A([\d.]+)\s*pt\z/ then $1.to_f
    else value.to_f
    end
  end
end
