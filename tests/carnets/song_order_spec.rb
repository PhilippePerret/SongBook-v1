# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"

RSpec.describe "CarnetBuilder.plan_song_order (#54)" do
  it "ne touche rien si aucune chanson à nombre de pages pair ne tombe mal" do
    counts = { "A1" => 3, "A2" => 2, "A3" => 1 }
    expect(CarnetBuilder.plan_song_order(%w[A1 A2 A3], counts, 8, true, true)).to eq(%w[A1 A2 A3])
  end

  it "échange avec la première chanson suivante à nombre de pages impair" do
    counts = { "A1" => 2, "B" => 2, "C" => 1 }
    expect(CarnetBuilder.plan_song_order(%w[A1 B C], counts, 8, true, true)).to eq(%w[C A1 B])
  end

  it "insère une page vide si aucune chanson à nombre de pages impair ne suit" do
    counts = { "A1" => 2, "B" => 2 }
    expect(CarnetBuilder.plan_song_order(%w[A1 B], counts, 8, true, true)).to eq([:blank, "A1", "B"])
  end

  it "insère une page vide même si le réordonnancement est interdit" do
    counts = { "A1" => 2, "B" => 1 }
    expect(CarnetBuilder.plan_song_order(%w[A1 B], counts, 8, false, true)).to eq([:blank, "A1", "B"])
  end

  it "ne fait rien si facing_pages est false" do
    counts = { "A1" => 2, "B" => 2 }
    expect(CarnetBuilder.plan_song_order(%w[A1 B], counts, 8, true, false)).to eq(%w[A1 B])
  end
end
