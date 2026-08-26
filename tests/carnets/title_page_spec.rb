# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"

# Tests des carnets
RSpec.describe "page de titre d'un carnet" do
  it "Mettre le titre, le sous-titre et l'éditeur sur une page de titre" do
    specs = CarnetBuilder.front_matter_specs({ "title_page" => true }, nil, [], editor_name: "Éditions Test", book_designer: "Philippe")
    spec = specs.find { |s| s[:kind] == :title_page }

    expect(spec[:editor_name]).to eq("Éditions Test")
    expect(spec[:byline]).to eq("Conçu par Philippe")
  end

  it "Mettre le vrai auteur plutôt que le concepteur, s'il y en a un" do
    specs = CarnetBuilder.front_matter_specs({ "title_page" => true }, nil, [], author: "Jean Dupont", book_designer: "Philippe")
    spec = specs.find { |s| s[:kind] == :title_page }

    expect(spec[:byline]).to eq("Jean Dupont")
  end

  it "Ne rien mettre du tout si title_page n'est pas demandé" do
    specs = CarnetBuilder.front_matter_specs({}, nil, [])
    expect(specs.map { |s| s[:kind] }).not_to include(:title_page)
  end

  it "Ne pas confondre avec la page de garde (les deux peuvent coexister, ce sont deux choses différentes)" do
    specs = CarnetBuilder.front_matter_specs({ "pages_garde" => true, "title_page" => true }, nil, [])
    expect(specs.map { |s| s[:kind] }).to eq(%i[garde title_page])
  end
end
