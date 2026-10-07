# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"
require "page_builder"
require "printer_profile"

# Positions composées de `diags_position` : l'ORDRE compte.
#   `End-Left`/`Top-Right`... : rangée horizontale, alignement IMPOSÉ ;
#   `Left-Top`/`Right-Top`... : colonne à côté des premières paroles.
RSpec.describe "positions composées des diagrammes (diags_position)" do
  def split(pos, align = :justify)
    PageBuilder.split_diag_position(pos, align)
  end

  it "End-Left/End-Right/Top-Left/Top-Right : rangée avec alignement imposé" do
    expect(split(:"end-left")).to eq([:end, :"fixed-left"])
    expect(split(:"end-right")).to eq([:end, :"fixed-right"])
    expect(split(:"top-left")).to eq([:top, :"fixed-left"])
    expect(split(:"top-right")).to eq([:top, :"fixed-right"])
    expect(split(:"end-ext")).to eq([:end, :"fixed-ext"])
    expect(split(:"top-int")).to eq([:top, :"fixed-int"])
  end

  it "Left-Top/Right-Top/Ext-Top/Int-Top : colonne, alignement inchangé" do
    expect(split(:"left-top")).to eq([:left, :justify])
    expect(split(:"right-top")).to eq([:right, :justify])
    expect(split(:"ext-top")).to eq([:ext, :justify])
    expect(split(:"int-top")).to eq([:int, :justify])
  end

  it "Left-End/Right-End/End/Top et autres valeurs : inchangées" do
    %i[left-end right-end ext-end int-end end top left-right back].each do |pos|
      expect(split(pos)).to eq([pos, :justify])
    end
  end

  it "alignement imposé jamais recentré par RAD12, même pour une rangée courte" do
    expect(Layout.rad12_align(:"fixed-left", 1000, 2, 60)).to eq(:left)
    expect(Layout.rad12_align(:"fixed-right", 1000, 2, 60)).to eq(:right)
    expect(Layout.rad12_align(:left, 1000, 2, 60)).to eq(:center)
  end

  it "Ext/Int résolus selon la page (int = gauche sur recto)" do
    printer = PrinterProfile.new(page_count: 4, trim_width: 6, trim_height: 9, facing_pages: true)
    expect(Layout.resolve_fixed_align(:"fixed-int", printer, 3)).to eq(:"fixed-left")
    expect(Layout.resolve_fixed_align(:"fixed-ext", printer, 3)).to eq(:"fixed-right")
    expect(Layout.resolve_fixed_align(:"fixed-int", printer, 2)).to eq(:"fixed-right")
    expect(Layout.resolve_fixed_align(:"fixed-ext", printer, 2)).to eq(:"fixed-left")
    expect(Layout.resolve_fixed_align(:"fixed-left", printer, 2)).to eq(:"fixed-left")
  end
end
