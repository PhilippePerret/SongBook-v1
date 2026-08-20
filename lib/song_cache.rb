require_relative "page_builder"

# Cache des infos de chansons, un fichier Marshal par `chansons_dir` — évite de relire/
# parser tous les `.infos` à chaque recherche (Phil, 2026-08-20 : `stat()` quasi gratuit,
# parser systématiquement coûte cher sur beaucoup de chansons). 3 tables : nom de dossier
# -> id, titre -> id, id -> {folder:, infos:, checked_at:} (`checked_at` = mtime du
# `.infos` vue au dernier parsing, sert à savoir s'il faut relire).
module SongCache
  CACHE_FILE = ".songs_cache.marshal"

  @caches = {}
  @dirty = {}

  def self.cache_path(chansons_dir)
    File.join(chansons_dir, CACHE_FILE)
  end

  def self.load(chansons_dir)
    @caches[chansons_dir] ||= begin
      path = cache_path(chansons_dir)
      File.exist?(path) ? Marshal.load(File.binread(path)) : { by_folder: {}, by_title: {}, by_id: {} }
    end
  end

  # N'écrit RIEN si rien n'a changé depuis le dernier `save` (Phil, 2026-08-20).
  def self.save(chansons_dir)
    return unless @dirty[chansons_dir]

    File.binwrite(cache_path(chansons_dir), Marshal.dump(load(chansons_dir)))
    @dirty[chansons_dir] = false
  end

  def self.infos_path(chansons_dir, folder_name)
    Dir.glob(File.join(chansons_dir, folder_name, "*.infos")).first
  end

  # `name` = nom de dossier, titre OU id — cherché dans les 3 tables du cache. Trouvé :
  # `refresh` (relit le `.infos` SEULEMENT si sa mtime a bougé depuis `checked_at`).
  # Pas trouvé en cache : scan disque (`find_on_disk`) — chanson déjà là mais jamais
  # encore mise en cache. Toujours introuvable : le bloc fourni par l'appelant décide
  # (ex. création automatique) ; `nil` du bloc (ou absence de bloc) -> `resolve` renvoie
  # `nil`. Dans tous les cas où quelque chose est trouvé/créé : consigné dans le cache.
  def self.resolve(chansons_dir, name)
    cache = load(chansons_dir)
    id = cache[:by_folder][name] || cache[:by_title][name] || (cache[:by_id].key?(name) ? name : nil)
    return refresh(chansons_dir, id) if id

    entry = find_on_disk(chansons_dir, name)
    entry ||= yield(name) if block_given?
    return nil unless entry

    register(chansons_dir, entry[:folder], entry[:infos])
  end

  def self.refresh(chansons_dir, id)
    cache = load(chansons_dir)
    entry = cache[:by_id][id]
    path = infos_path(chansons_dir, entry[:folder])
    return entry unless path

    mtime = File.mtime(path).to_f
    return entry if mtime <= entry[:checked_at]

    register(chansons_dir, entry[:folder], PageBuilder.parse_infos(path), id: id)
  end

  def self.register(chansons_dir, folder, infos, id: infos["id"])
    cache = load(chansons_dir)
    path = infos_path(chansons_dir, folder)
    checked_at = path ? File.mtime(path).to_f : Time.now.to_f

    cache[:by_folder][folder] = id
    cache[:by_title][infos["title"]] = id if infos["title"]
    entry = { folder: folder, infos: infos, checked_at: checked_at }
    cache[:by_id][id] = entry
    @dirty[chansons_dir] = true
    entry
  end

  # Recherche EXHAUSTIVE sur disque (nom de dossier exact, puis id/titre de chaque
  # `.infos`) — seulement en cas d'échec du cache (chanson pas encore consignée).
  def self.find_on_disk(chansons_dir, name)
    direct = File.join(chansons_dir, name)
    if Dir.exist?(direct) && !Dir.glob(File.join(direct, "*.lyr")).empty?
      path = infos_path(chansons_dir, name)
      return { folder: name, infos: path ? PageBuilder.parse_infos(path) : {} }
    end

    Dir.children(chansons_dir).each do |dirname|
      path = infos_path(chansons_dir, dirname)
      next unless path

      infos = PageBuilder.parse_infos(path)
      return { folder: dirname, infos: infos } if infos["id"] == name || infos["title"] == name
    end
    nil
  end
end
