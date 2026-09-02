# frozen_string_literal: true

require_relative "../spec_helper"
require "printer_profile"

# Tests des outils
RSpec.describe "gabarit imprimeur (PrinterProfile, profil Amazon KDP)" do
  let(:printer) { PrinterProfile.new(page_count: 100, trim_width: 6, trim_height: 8.25, paper: :white) }

  it "Accrocher la marge de reliure à la plage la plus proche pour un nombre de pages hors plages" do
    petit = PrinterProfile.new(page_count: 3, trim_width: 6, trim_height: 8.25)
    grand = PrinterProfile.new(page_count: 900, trim_width: 6, trim_height: 8.25)
    vingt_quatre = PrinterProfile.new(page_count: 24, trim_width: 6, trim_height: 8.25)
    huit_cent_vingt_huit = PrinterProfile.new(page_count: 828, trim_width: 6, trim_height: 8.25)
    expect(petit.gutter_margin).to eq(vingt_quatre.gutter_margin)
    expect(grand.gutter_margin).to eq(huit_cent_vingt_huit.gutter_margin)
  end

  it "Donner la plage totale de pages connues" do
    expect(PrinterProfile.page_count_range).to eq([24, 828])
  end

  it "Donner une marge de reliure plus grande pour un livre plus épais" do
    fin = PrinterProfile.new(page_count: 100, trim_width: 6, trim_height: 8.25)
    epais = PrinterProfile.new(page_count: 600, trim_width: 6, trim_height: 8.25)
    expect(epais.gutter_margin).to be > fin.gutter_margin
  end

  it "Mettre la marge de reliure à gauche sur une page de droite (impaire)" do
    expect(printer.left_margin(3)).to eq(printer.gutter_margin)
    expect(printer.right_margin(3)).to eq(printer.outside_margin)
  end

  it "Mettre la marge de reliure à droite sur une page de gauche (paire)" do
    expect(printer.right_margin(4)).to eq(printer.gutter_margin)
    expect(printer.left_margin(4)).to eq(printer.outside_margin)
  end

  it "Un livre avec plus de papier est plus épais (dos plus large)" do
    petit = PrinterProfile.new(page_count: 50, trim_width: 6, trim_height: 8.25, paper: :white)
    gros = PrinterProfile.new(page_count: 500, trim_width: 6, trim_height: 8.25, paper: :white)
    expect(gros.spine_width).to be > petit.spine_width
  end

  it "Refuser un type de papier inconnu" do
    bizarre = PrinterProfile.new(page_count: 100, trim_width: 6, trim_height: 8.25, paper: :licorne)
    expect { bizarre.spine_width }.to raise_error(ArgumentError)
  end

  it "Un point pile au coin de la page n'est pas dans les marges" do
    expect(printer.inside_margins?(0, 0, page_no: 1)).to be false
  end

  it "Un point bien au centre de la page est dans les marges" do
    expect(printer.inside_margins?(printer.trim_width / 2, printer.trim_height / 2, page_no: 1)).to be true
  end
end
