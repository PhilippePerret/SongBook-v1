require "fileutils"
require "rqrcode"
require_relative "file_finder"

# QR-codes vers les pages en ligne du site des éditions (chanson : vidéo + indications
# d'interprétation ; carnet). Image produite par la commande `qrcode` dans le dossier
# `images` de la chanson/du carnet — insérée dans le PDF SEULEMENT si elle existe.
module QRCode
  SONG_URL = "https://www.icare-editions.fr/chansons/%s"
  CARNET_URL = "https://www.icare-editions.fr/carnets/%s"
  FILENAME = "QR-Code.svg"

  def self.path(folder)
    File.join(folder, "images", FILENAME)
  end

  def self.exist?(folder)
    File.exist?(path(folder))
  end

  # `id:` du `.infos`/`.inf` de la chanson ou du carnet.
  def self.id_of(folder)
    infos_path = FileFinder.find(folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
    infos["id"].to_s.strip
  end

  # Produit `images/QR-Code.svg` (`url_format` : `SONG_URL`/`CARNET_URL`). Renvoie
  # `{ status:, path:, url: }` — `:created`, `:exists` (rien touché) ou `:no_id`.
  def self.generate(folder, url_format)
    id = id_of(folder)
    return { status: :no_id, path: nil, url: nil } if id.empty?

    url = format(url_format, id)
    out = path(folder)
    return { status: :exists, path: out, url: url } if File.exist?(out)

    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, svg(url))
    { status: :created, path: out, url: url }
  end

  def self.svg(url)
    ::RQRCode::QRCode.new(url).as_svg(standalone: true, use_path: true, viewbox: true, module_size: 4, color: "000", fill: "fff")
  end
end
