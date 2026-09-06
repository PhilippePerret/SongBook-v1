# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"
require "tmpdir"

RSpec.describe "répétition de chanson dans un .tdm" do
  describe "CarnetBuilder.strip_repeat_index" do
    it "retire l'index entre crochets" do
      expect(CarnetBuilder.strip_repeat_index("blackbird-the-beatles-1968 [1]")).to eq("blackbird-the-beatles-1968")
    end

    it "accepte n'importe quel contenu de crochets (pas que des chiffres)" do
      expect(CarnetBuilder.strip_repeat_index("blackbird-the-beatles-1968 [drop-d]")).to eq("blackbird-the-beatles-1968")
    end

    it "laisse un identifiant sans index inchangé" do
      expect(CarnetBuilder.strip_repeat_index("blackbird-the-beatles-1968")).to eq("blackbird-the-beatles-1968")
    end
  end

  describe "CarnetBuilder.resolve_infos_override" do
    let(:carnet_folder) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test") }
    let(:song_folder) { File.join(FIXTURE_SONGS_DIR, "Angie") }

    it "renvoie {} si aucun fichier indexé n'existe" do
      expect(CarnetBuilder.resolve_infos_override(carnet_folder, song_folder, "Angie [99]")).to eq({})
    end

    it "trouve le fichier dans le dossier du carnet, prioritaire sur le dossier de la chanson" do
      carnet_override = File.join(carnet_folder, "Angie [1].infos")
      song_override = File.join(song_folder, "Angie [1].infos")
      File.write(carnet_override, "title: Angie (du carnet)\n")
      File.write(song_override, "title: Angie (de la chanson)\n")

      begin
        expect(CarnetBuilder.resolve_infos_override(carnet_folder, song_folder, "Angie [1]")["title"]).to eq("Angie (du carnet)")
      ensure
        File.delete(carnet_override)
        File.delete(song_override)
      end
    end

    it "retombe sur le dossier de la chanson si rien dans le carnet" do
      song_override = File.join(song_folder, "Angie [2].infos")
      File.write(song_override, "font-size: 14\n")

      begin
        expect(CarnetBuilder.resolve_infos_override(carnet_folder, song_folder, "Angie [2]")["font-size"]).to eq("14")
      ensure
        File.delete(song_override)
      end
    end

    it "fonctionne aussi sans index (id nu)" do
      override = File.join(carnet_folder, "Angie.infos")
      File.write(override, "font-family: Garamond\n")

      begin
        expect(CarnetBuilder.resolve_infos_override(carnet_folder, song_folder, "Angie")["font-family"]).to eq("Garamond")
      ensure
        File.delete(override)
      end
    end
  end

  describe "construction d'un carnet avec chanson répétée + override" do
    let(:carnet_folder) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Repeat") }
    let(:export_dir) { File.join(carnet_folder, "export") }

    before do
      FileUtils.mkdir_p(carnet_folder)
      File.write(File.join(carnet_folder, "c.infos"), "title: Carnet Répétition\n")
      # >= 24 pages exigées par les plages KDP (`PrinterProfile::GUTTER_RANGES`) — répète assez
      # de fois pour dépasser ce plancher, sans rapport avec la fonctionnalité testée.
      tdm_lines = (1..15).map { |i| "- Angie [#{i}]" }
      File.write(File.join(carnet_folder, "c.tdm"), "#{tdm_lines.join("\n")}\n")
      File.write(File.join(carnet_folder, "Angie [2].infos"), "title: Angie (reprise)\nshow_specs: true\nfont-size: 14\n")
    end

    after { FileUtils.rm_rf(carnet_folder) }

    it "construit sans erreur, chaque occurrence résolue vers le même dossier chanson" do
      out_path = CarnetBuilder.build(carnet_folder)

      expect(File.exist?(out_path)).to be true
      expect(File.size(out_path)).to be > 0
    end
  end

  describe "Layout.song_specs_line" do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def load_options(infos)
      path = File.join(@dir, "c.infos")
      File.write(path, infos)
      Options.load!(meta: {}, infos_path: path, carnet_folder: nil)
    end

    it "vide si rien n'est fixé explicitement" do
      load_options("title: Chanson\n")
      expect(Layout.song_specs_line).to eq("")
    end

    it "montre la taille de police si fixée" do
      load_options("title: Chanson\nfont-size: 14\n")
      expect(Layout.song_specs_line).to eq("(font-size 14pt)")
    end

    it "montre police + taille si les deux sont fixées" do
      load_options("title: Chanson\nfont-family: Garamond\nfont-size: 14\n")
      expect(Layout.song_specs_line).to eq("(font-family Garamond) (font-size 14pt)")
    end

    it "montre la taille des diags si fixée en imbriqué" do
      load_options("title: Chanson\ndiags:\n  size: 32pt x\n")
      expect(Layout.song_specs_line).to eq("(diags_size 32pt)")
    end
  end

  describe "cascade défaut < carnet < chanson < chanson indexée (PageBuilder.build)" do
    around do |example|
      Dir.mktmpdir do |carnet_dir|
        Dir.mktmpdir do |song_dir|
          @carnet_dir = carnet_dir
          @song_dir = song_dir
          File.write(File.join(song_dir, "c.lyr"), "{couplet}\nla la la\n")
          example.run
        end
      end
    end

    def build(song_infos:, carnet_infos: "title: Carnet\n", overrides: {})
      File.write(File.join(@carnet_dir, "c.infos"), carnet_infos)
      File.write(File.join(@song_dir, "c.infos"), song_infos)
      Layout.building_log_path = File.join(@song_dir, "building.log")
      Layout.conflict_log_path = File.join(@song_dir, "conflicts.log")
      File.write(Layout.building_log_path, "")
      File.write(Layout.conflict_log_path, "")
      out_path = File.join(@song_dir, "out.pdf")
      PageBuilder.build(@song_dir, out_path, page_size_in: [3.5, 5], page_count: 24, first_page_no: 1,
        carnet_folder: @carnet_dir, infos_overrides: overrides)
    end

    it "la chanson hérite d'une clé définie SEULEMENT au niveau du carnet" do
      build(song_infos: "title: Chanson\n", carnet_infos: "title: Carnet\nfont-family: Georgia\n")
      expect(Options.get(:font_family)).to eq("Georgia")
    end

    it "la chanson écrase la valeur du carnet" do
      build(song_infos: "title: Chanson\nfont-family: Futura\n", carnet_infos: "title: Carnet\nfont-family: Georgia\n")
      expect(Options.get(:font_family)).to eq("Futura")
    end

    it "le .infos indexé écrase la chanson ET le carnet" do
      build(song_infos: "title: Chanson\nfont-family: Futura\n", carnet_infos: "title: Carnet\nfont-family: Georgia\n",
        overrides: { "font-family" => "Bodoni" })
      expect(Options.get(:font_family)).to eq("Bodoni")
    end
  end
end
