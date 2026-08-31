# frozen_string_literal: true

require_relative "../spec_helper"
require "page_builder"
require "layout"
require "tmpdir"
require "fileutils"

# Fusion de tablatures ("+" dans le nom) — `{tabla: intro+couplet}` =
# mise bout à bout PURE des codes de "intro.tab" et "couplet.tab", un seul SVG produit.
RSpec.describe "fusion de tablatures (\"+\")" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Layout.building_log_path = File.join(dir, "building.log")
      File.write(Layout.building_log_path, "")
      example.run
    end
  end

  def write_tab(name, front, body)
    File.write(File.join(@dir, "#{name}.tab"), "---\n#{front}\n---\n#{body}\n")
  end

  describe ".tab_source_content (nom avec \"+\")" do
    it "renvoie les contenus SÉPARÉS, dans l'ordre  : chaque source garde sa propre métrique)" do
      write_tab("intro", "title: Intro", "50/4 60/4 |")
      write_tab("couplet", "title: Couplet", "70/4 |")

      contents, dir, paths = PageBuilder.tab_source_content(@dir, "intro+couplet")

      expect(contents).to eq(["---\ntitle: Intro\n---\n50/4 60/4 |\n", "---\ntitle: Couplet\n---\n70/4 |\n"])
      expect(dir).to eq(@dir)
      expect(paths).to eq([File.join(@dir, "intro.tab"), File.join(@dir, "couplet.tab")])
    end

    it "nil si une source manque" do
      write_tab("intro", "title: Intro", "50/4")
      expect(PageBuilder.tab_source_content(@dir, "intro+couplet")).to be_nil
    end
  end

  describe "changement de métrique d'une source à l'autre " do
    it "chaque mesure garde SA PROPRE métrique, jamais celle du 1er fichier imposée aux autres" do
      write_tab("amorce", "title: Amorce\nmetrique: 3/4", "s4 50/4 60/4 |")
      write_tab("intro", "title: Intro", "10/4 20/4 30/4 40/4 |")

      contents, = PageBuilder.tab_source_content(@dir, "amorce+intro")
      measures = contents.flat_map { |c| Tablator.parse_source_measures(c).first }

      expect(measures[0][:time]).to eq("3/4")
      expect(measures[1][:time]).to eq("4/4")
    end
  end

  describe ".ensure_tabla_svg (nom avec \"+\")" do
    it "nil si l'une des sources manque" do
      write_tab("intro", "title: Intro", "50/4")
      # "couplet.tab" n'existe pas.
      expect(PageBuilder.ensure_tabla_svg(@dir, "intro+couplet")).to be_nil
    end

    it "produit le SVG fusionné (\"intro+couplet.svg\"), fichier temporaire nettoyé" do
      write_tab("intro", "title: Intro", "50/4")
      write_tab("couplet", "title: Couplet", "60/4")
      svg_path = File.join(@dir, "intro+couplet.svg")

      expect(PageBuilder).to receive(:system).with("ruby", PageBuilder::TABLATOR_PATH, File.join(@dir, ".~intro+couplet.tab"), "-o", File.join(@dir, "intro+couplet"), out: File::NULL, err: File::NULL) do
        File.write(svg_path, "<svg/>") # simule la production par tablator (pas de vrai lilypond ici)
        true
      end

      result = PageBuilder.ensure_tabla_svg(@dir, "intro+couplet")

      expect(result).to eq(svg_path)
      expect(Dir.glob(File.join(@dir, ".~*.tab"))).to be_empty # fichier temporaire détruit
    end

    it "réutilise le SVG déjà produit si aucune source n'a changé depuis (cache)" do
      write_tab("intro", "title: Intro", "50/4")
      write_tab("couplet", "title: Couplet", "60/4")
      svg_path = File.join(@dir, "intro+couplet.svg")
      File.write(svg_path, "<svg/>")
      FileUtils.touch(svg_path, mtime: Time.now + 10) # plus récent que les sources

      expect(PageBuilder).not_to receive(:system)
      expect(PageBuilder.ensure_tabla_svg(@dir, "intro+couplet")).to eq(svg_path)
    end
  end
end
