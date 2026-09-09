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
    it "tableau vide si l'une des sources manque" do
      write_tab("intro", "title: Intro", "50/4")
      # "couplet.tab" n'existe pas.
      expect(PageBuilder.ensure_tabla_svg(@dir, "intro+couplet", 300)).to eq([])
    end

    it "produit le(s) SVG (rendu géométrique direct, un fichier par système) dans .export/" do
      write_tab("intro", "title: Intro", "50/4")
      write_tab("couplet", "title: Couplet", "60/4")

      result = PageBuilder.ensure_tabla_svg(@dir, "intro+couplet", 300)

      expect(result).not_to be_empty
      expect(result.first).to match(%r{/\.export/intro\+couplet\..*\.s1\.svg\z})
      expect(File.read(result.first)).to include("<svg")
    end

    it "réutilise le SVG déjà produit si aucune source n'a changé depuis (cache)" do
      write_tab("intro", "title: Intro", "50/4")
      write_tab("couplet", "title: Couplet", "60/4")

      first = PageBuilder.ensure_tabla_svg(@dir, "intro+couplet", 300)
      mtime_before = File.mtime(first.first)
      second = PageBuilder.ensure_tabla_svg(@dir, "intro+couplet", 300)

      expect(second).to eq(first)
      expect(File.mtime(second.first)).to eq(mtime_before)
    end
  end
end
