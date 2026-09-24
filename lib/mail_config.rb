# frozen_string_literal: true

require "yaml"
require "rbconfig"
require "fileutils"
require "io/console"
require "net/smtp"

# Identifiants d'envoi (SMTP + adresse d'expédition) pour `RightsMailer` — demandés à
# l'user un par un, UNIQUEMENT pour ce qui manque (comme `AppConfig.ensure_folder`), puis
# enregistrés HORS du repo, dans le dossier de données applicatives standard de l'OS —
# jamais dans `config.yaml` (tracké par git, un secret n'y a rien à faire) (Phil,
# 2026-09-22, "les enregistrer dans le dossier des données de l'user, en fonction de son
# système d'exploitation").
module MailConfig
  APP_NAME = "SongBook"
  FILE_NAME = "mail_credentials.yaml"

  QUESTIONS = {
    server: "Serveur SMTP",
    port: "Port SMTP",
    domain: "Domaine (EHLO)",
    user_name: "Identifiant SMTP",
    password: "Mot de passe SMTP",
    from_email: "Adresse d'expédition (From) pour les demandes de droits",
  }.freeze

  # macOS : `~/Library/Application Support/<app>`. Windows : `%APPDATA%\<app>`. Autres
  # (Linux…) : `$XDG_CONFIG_HOME/<app>` ou `~/.config/<app>` à défaut — mêmes familles
  # d'OS que `AppConfig.editor_app?`.
  def self.data_dir
    dir = case RbConfig::CONFIG["host_os"]
          when /darwin/
            File.expand_path("~/Library/Application Support/#{APP_NAME}")
          when /mswin|mingw|cygwin/
            File.join(ENV["APPDATA"] || File.expand_path("~"), APP_NAME)
          else
            File.join(ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config"), APP_NAME.downcase)
          end
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.path
    File.join(data_dir, FILE_NAME)
  end

  def self.load
    return {} unless File.exist?(path)

    (YAML.safe_load_file(path) || {}).transform_keys(&:to_sym)
  end

  def self.save(data)
    File.write(path, data.transform_keys(&:to_s).to_yaml)
    File.chmod(0o600, path)
  rescue StandardError
    nil
  end

  # -> `{server:, port:, domain:, user_name:, password:, from_email:}`, complété au
  # clavier pour chaque clé manquante — puis, seulement si quelque chose vient d'être
  # saisi, une connexion SMTP réelle est essayée AVANT d'enregistrer (Phil, 2026-09-22,
  # "être sûr d'avoir les bonnes") : rien n'est persisté si le test échoue, pour ne
  # jamais sauver silencieusement des identifiants faux (l'user retapera tout au
  # prochain essai — sciemment, pas une perte cachée).
  def self.ensure!
    data = load
    dirty = false

    QUESTIONS.each do |key, question|
      next unless data[key].to_s.strip.empty?

      data[key] = key == :password ? $stdin.getpass("#{question} : ") : ask(question)
      dirty = true
    end

    if dirty
      ok, error = test_connection(data)
      raise "connexion SMTP refusée avec ces identifiants (rien n'a été enregistré) : #{error}" unless ok

      save(data)
      puts "Connexion SMTP vérifiée."
    end

    data
  end

  # Connexion + STARTTLS + AUTH réels, SANS envoyer de mail (pas de `send_message`) —
  # juste vérifier que le serveur accepte ces identifiants.
  def self.test_connection(data)
    smtp = Net::SMTP.new(data[:server], data[:port].to_i)
    smtp.enable_starttls_auto
    smtp.start(data[:domain], data[:user_name], data[:password], :plain) { |_s| nil }
    [true, nil]
  rescue StandardError => e
    [false, e.message]
  end

  def self.ask(question)
    print "#{question} : "
    $stdin.gets.to_s.strip
  end
end
