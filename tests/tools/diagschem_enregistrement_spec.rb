# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../tools/DiagSchem/diagschem"
require "tmpdir"

# `enregistrer_dans_application` : le texte tapé à "Nom à donner au schéma" EST le nom
# exact, tel quel, à la fois du fichier SVG ET de l'entrée dans `schemas.txt` (Phil,
# 2026-08-26 — rien n'est reconstruit/ajouté derrière).
RSpec.describe "DiagSchem#enregistrer_dans_application" do
  let(:prompt) { instance_double(TTY::Prompt) }
  let(:schemas_txt) { File.join(@dir, "schemas.txt") }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  def build_instance(schema)
    instance = DiagSchem.new(schema: schema)
    instance.instance_variable_set(:@sortie, "#{schema.split(':').first.strip} : #{schema.split(':', 2).last.strip}")
    instance
  end

  it "défaut proposé = \"Nom-case\", pas juste \"Nom\" (issue #61)" do
    instance = build_instance("C7-0: 10 21/1 32/3 42/2 50 6x")
    allow(SchemaLibrary).to receive(:schemas_path).and_return(schemas_txt)
    expect(prompt).to receive(:ask).with(anything, default: "C7-0").and_return("C7-0")

    instance.send(:enregistrer_dans_application, prompt)
  end

  it "nom tapé en minuscule (\"cd[e]\") : défaut proposé déjà normalisé (\"Cd[E]-5\", issue diag/#69) — 1re lettre fondamentale ET basse capitalisées, rien d'autre" do
    instance = build_instance("cd[e]-5: 10 21/1 32/3 42/2 50 6x")
    allow(SchemaLibrary).to receive(:schemas_path).and_return(schemas_txt)
    expect(prompt).to receive(:ask).with(anything, default: "Cd[E]-5").and_return("Cd[E]-5")

    instance.send(:enregistrer_dans_application, prompt)
  end

  it "texte tapé avec case ('Am7-3') : ligne schemas.txt et nom du SVG identiques au texte tapé" do
    instance = build_instance("Am7-0: 10 21/1 32/3 42/2 50 6x")
    allow(SchemaLibrary).to receive(:schemas_path).and_return(schemas_txt)
    allow(prompt).to receive(:ask).and_return("Am7-3")

    instance.send(:enregistrer_dans_application, prompt)

    expect(File.read(schemas_txt)).to eq("Am7-3 : 10 21/1 32/3 42/2 50 6x\n")
    expect(File.exist?("Am7-3.svg")).to be true
  end

  it "texte tapé SANS case : la case en cours dans le tableau reconstitue la ligne schemas.txt, mais le SVG garde le texte tapé tel quel" do
    instance = build_instance("Am7-0: 10 21/1 32/3 42/2 50 6x")
    allow(SchemaLibrary).to receive(:schemas_path).and_return(schemas_txt)
    allow(prompt).to receive(:ask).and_return("Am7bis")

    instance.send(:enregistrer_dans_application, prompt)

    expect(File.read(schemas_txt)).to eq("Am7bis-0 : 10 21/1 32/3 42/2 50 6x\n")
    expect(File.exist?("Am7bis.svg")).to be true
  end
end
