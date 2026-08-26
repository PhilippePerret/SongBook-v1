# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../tools/DiagSchem/diagschem"
require "tmpdir"

# `generer_svg` : le nom du fichier écrit doit être EXACTEMENT celui donné (Phil,
# 2026-08-26 : le nom tapé à "Nom à donner au schéma" EST le nom du fichier, la case ne
# doit RIEN y ajouter). Sans argument, comportement historique conservé (nom-case.svg,
# utilisé par le flux `-o`/schéma en ligne de commande où le nom seul ne suffit pas).
RSpec.describe "DiagSchem#generer_svg" do
  let(:schema) { "Am7-0: 10 21/1 32/3 42/2 50 6x" }

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  it "chemin explicite fourni : utilisé TEL QUEL, aucune case ajoutée" do
    instance = DiagSchem.new(schema: schema)
    chemin = instance.send(:generer_svg, "MonNomChoisi.svg")

    expect(chemin).to eq("MonNomChoisi.svg")
    expect(File.exist?("MonNomChoisi.svg")).to be true
    expect(File.exist?("Am7-0.svg")).to be false
  end

  it "sans argument : nom-case.svg (comportement historique, flux ligne de commande)" do
    instance = DiagSchem.new(schema: schema)
    chemin = instance.send(:generer_svg)

    expect(chemin).to eq("Am7-0.svg")
  end
end
