# frozen_string_literal: true

require_relative "../spec_helper"
require "cover_builder"
require "cov_parser"

# Tests des outils
RSpec.describe "champs de la couverture (.cover)" do
  let(:conf) do
    {
      "title" => "Mon Carnet",
      "editor" => { "name" => "Éditions Test", "logo" => "logo.svg" },
      "isbn" => "978-2-1234-5678-9",
    }
  end

  it "Lire le titre du carnet" do
    expect(CoverBuilder.field_value("title", conf)).to eq("Mon Carnet")
  end

  it "Lire le nom et le logo de l'éditeur" do
    expect(CoverBuilder.field_value("editor_name", conf)).to eq("Éditions Test")
    expect(CoverBuilder.field_value("editor_logo", conf)).to eq("logo.svg")
  end

  it "Lire le numéro ISBN" do
    expect(CoverBuilder.field_value("isbn", conf)).to eq("978-2-1234-5678-9")
  end

  it "Ne rien renvoyer pour une information absente" do
    expect(CoverBuilder.field_value("subtitle", conf)).to be_nil
  end

  it "Choisir le premier nom qui a vraiment une valeur, parmi plusieurs proposés" do
    item = CovParser::Item.new(names: ["subtitle", "title"], props: {})
    expect(CoverBuilder.resolve_name(item, conf, [])).to eq("title")
  end
end
