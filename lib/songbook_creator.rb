# frozen_string_literal: true

require "tty-prompt"
require "rbconfig"
require_relative "carnet_builder"
require_relative "app_config"
require_relative "ansi_colors"
require_relative "locale"
require_relative "file_finder"

# `songbook create songbook`/`create sb` : wizard interactif (TTY::Prompt) pour un
# nouveau carnet — inspiré de la structure RÉELLE des carnets existants (Carnet-1,
# seul carnet à ce jour avec un `.infos` complet). Ne demande que les champs qui
# varient vraiment d'un carnet à l'autre (titre/sous-titre/prix/éditeur/conception) ;
# le reste (front_matter, credits, copyright) est écrit avec des valeurs par défaut
# raisonnables, à ajuster ensuite dans le fichier ouvert — même économie que
# `SongCreator` (titre/interprète demandés, le reste réglé après ou par défaut).
module SongbookCreator
  def self.run(title = nil)
    prompt = TTY::Prompt.new

    title ||= prompt.ask(blue("Titre du carnet :")) { |q| q.required true }
    folder_name = prompt.ask(blue("Nom du dossier :"), default: "Carnet-#{CarnetBuilder.slugify(title)}") { |q| q.required true }

    songbooks_dir = AppConfig.songbooks_dir
    folder = File.join(songbooks_dir, folder_name)
    return handle_existing_songbook(prompt, folder) if Dir.exist?(folder)

    subtitle = prompt.ask(blue("Sous-titre (rien si aucun) :"))
    price = prompt.ask(blue("Prix (ex. 9,90 € — rien si inconnu) :"))
    editor_name = prompt.ask(blue("Nom de l'éditeur (rien si aucun) :"))
    book_designer = prompt.ask(blue("Conception du carnet (rien si inconnu) :"))

    infos = default_infos(title: title, subtitle: subtitle, price: price, editor_name: editor_name, book_designer: book_designer)

    Dir.mkdir(folder)
    infos_path = File.join(folder, "c.infos")
    tdm_path = File.join(folder, "c.tdm")
    File.write(infos_path, "#{serialize_nested_infos(infos)}\n")
    File.write(tdm_path, "")

    editor = AppConfig.user_song_editor
    system("open", "-a", editor, infos_path, tdm_path)

    print_success(Loc.get("songbook_created"))
    offer_open_folder(prompt, folder)
    folder
  end

  # `.infos` déjà là (dossier existant) : rien à "compléter" comme pour une chanson
  # (pas de recherche web ici) — juste proposer d'ouvrir le dossier.
  def self.handle_existing_songbook(prompt, folder)
    puts format(Loc.get("songbook_exists"), folder)
    offer_open_folder(prompt, folder)
    nil
  end

  def self.default_infos(title:, subtitle:, price:, editor_name:, book_designer:)
    infos = { "title" => title }
    infos["subtitle"] = subtitle unless subtitle.to_s.strip.empty?
    infos["format"] = AppConfig.get("format")
    infos["price"] = price unless price.to_s.strip.empty?
    infos["editor"] = { "name" => editor_name, "logo" => "" } unless editor_name.to_s.strip.empty?
    infos["front_matter"] = {
      "half_title_page" => false,
      "pages_garde" => true,
      "table_of_contents" => {
        "per_song" => true,
        "per_performer" => false,
        "per_composer" => false,
        "per_author" => false,
      },
      "forword" => false,
      "preface" => false,
      "acknowledgments" => false,
    }
    infos["copyright"] = ""
    infos["credits"] = {
      "book_designer" => book_designer.to_s,
      "typesetter" => "",
      "proofreader" => "",
      "programming" => "",
    }
    infos
  end

  def self.serialize_nested_infos(hash, indent = 0)
    hash.map do |k, v|
      prefix = "  " * indent
      if v.is_a?(Hash)
        "#{prefix}#{k}:\n#{serialize_nested_infos(v, indent + 1)}"
      else
        "#{prefix}#{k}: #{v}"
      end
    end.join("\n")
  end

  def self.offer_open_folder(prompt, folder)
    return unless prompt.yes?(blue(Loc.get("open_folder_question")))

    open_in_file_manager(folder)
  end

  # Bleu (`AnsiColors::BLUE`) pour toute question posée à l'user (Phil).
  def self.blue(text)
    "#{AnsiColors::BLUE}#{text}#{AnsiColors::RESET}"
  end

  def self.open_in_file_manager(folder)
    case RbConfig::CONFIG["host_os"]
    when /darwin/ then system("open", folder)
    when /mswin|mingw|cygwin/ then system("explorer", folder)
    else system("xdg-open", folder)
    end
  end

  def self.print_success(message)
    puts "#{AnsiColors::SUCCESS}👍 #{message}#{AnsiColors::RESET}"
  end
end
