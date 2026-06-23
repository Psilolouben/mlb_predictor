require_relative './base_handler.rb'

class FantasyDataHandler < BaseHandler

  LEAGUE_AVG_RBI_PER_GAME = 0.50  # fallback if we can't fetch batter stats

  def stats
    @batter_stats_cache = {}
    all_lineups = lineups

    # Pre-fetch all batter stats in parallel (thread pool of 20)
    all_ids = all_lineups.flat_map { |l| l[:home][:player_ids] + l[:away][:player_ids] }.uniq
    puts "Pre-fetching stats for #{all_ids.length} batters in parallel..."
    mutex = Mutex.new
    all_ids.each_slice(20) do |batch|
      batch.map { |id| Thread.new { r = fetch_player_stat(id); mutex.synchronize { @batter_stats_cache[id] = r } } }.each(&:join)
    end
    puts "Batter pre-fetch done."

    all_lineups.each_with_object([]) do |l, arr|
      puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."

      unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
        puts "  Pitcher not found, skipping"
        next
      end

      puts "  #{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"

      home_row = pitcher_statcast(l[:home][:pitcher_id])
      away_row = pitcher_statcast(l[:away][:pitcher_id])

      home_pitcher_era      = statcast_val(home_row, :expected,    'xera')
      away_pitcher_era      = statcast_val(away_row, :expected,    'xera')
      home_pitcher_xwoba    = statcast_val(home_row, :expected,    'est_woba')
      away_pitcher_xwoba    = statcast_val(away_row, :expected,    'est_woba')
      home_pitcher_barrel   = statcast_val(home_row, :batted_ball, 'brl_pa')       / 100.0
      away_pitcher_barrel   = statcast_val(away_row, :batted_ball, 'brl_pa')       / 100.0
      home_pitcher_hard_hit = statcast_val(home_row, :batted_ball, 'ev95percent')  / 100.0
      away_pitcher_hard_hit = statcast_val(away_row, :batted_ball, 'ev95percent')  / 100.0

      puts "  Warning!!! #{l[:home][:pitcher_name]} has no xERA" if home_pitcher_era.zero?
      puts "  Warning!!! #{l[:away][:pitcher_name]} has no xERA" if away_pitcher_era.zero?

      arr << {
        home_team: l[:home][:name],
        away_team: l[:away][:name],
        home_pitcher: {
          era:          home_pitcher_era,
          k_rate:       0.0,
          bb_rate:      0.0,
          hard_hit_pct: home_pitcher_hard_hit,
          barrel_pct:   home_pitcher_barrel,
          whiff_pct:    0.0,
          xwoba:        home_pitcher_xwoba,
          name:         l[:home][:pitcher_name],
          era_warning:  home_pitcher_era.zero?
        },
        away_pitcher: {
          era:          away_pitcher_era,
          k_rate:       0.0,
          bb_rate:      0.0,
          hard_hit_pct: away_pitcher_hard_hit,
          barrel_pct:   away_pitcher_barrel,
          whiff_pct:    0.0,
          xwoba:        away_pitcher_xwoba,
          name:         l[:away][:pitcher_name],
          era_warning:  away_pitcher_era.zero?
        },
        home_avg_rbi: rbi_list(l[:home][:player_ids]),
        away_avg_rbi: rbi_list(l[:away][:player_ids])
      }
    end
  end

  def rbi_list(player_ids)
    values = player_ids.map { |id|
      s = @batter_stats_cache[id]
      s&.children.to_a[11]&.text.to_f.then { |v|
        g = s&.children.to_a[3]&.text.to_f
        g&.positive? ? v / g : nil
      }
    }.compact.select { |x| x.finite? && x > 0 && x < 1.5 }
    values.length >= 3 ? values : Array.new(9, LEAGUE_AVG_RBI_PER_GAME)
  end

  # Fetches the daily lineup page via plain HTTP — no Selenium needed, page is SSR
  def data
    response = HTTParty.get(
      games_url,
      headers: { 'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36' },
      timeout: 30
    )
    Nokogiri::HTML(response.body).xpath("//*[@class='lineup']")
  end

  def lineups
    blocks = data
    puts "Found #{blocks.length} lineup blocks from fantasydata.com"

    blocks.map do |m|
      home_players = m.children[3].children.map do |c|
        next if c.children.empty?
        c.children[3].nil? ? nil : c.children[3].attributes['href']&.value&.split('/')&.last
      end.compact
      home_players.delete_at(0)

      away_players = m.children[1].children.map do |c|
        next if c.children.empty?
        c.children[3].nil? ? nil : c.children[3].attributes['href']&.value&.split('/')&.last
      end.compact
      away_players.delete_at(0)

      team_text = m.parent.at_css('.info div').xpath('text()').first.text.strip
      home_team = team_text.split('@').last.gsub(/[[:space:]]/, '')
      away_team = team_text.split('@').first.gsub(/[[:space:]]/, '')

      match = savant_lineups.find { |x| x[:home][:name].split(' ').join.include?(home_team) }
      next unless match

      home_match_is_home = match[:home][:name].split(' ').join.include?(home_team)
      home_pitcher_id   = home_match_is_home ? match[:home][:pitcher_id]   : match[:away][:pitcher_id]
      home_pitcher_name = home_match_is_home ? match[:home][:pitcher_name] : match[:away][:pitcher_name]
      away_pitcher_id   = home_match_is_home ? match[:away][:pitcher_id]   : match[:home][:pitcher_id]
      away_pitcher_name = home_match_is_home ? match[:away][:pitcher_name] : match[:home][:pitcher_name]

      {
        id: 'koko',
        home: {
          name: home_team,
          pitcher_id:   home_pitcher_id,
          pitcher_name: home_pitcher_name,
          player_ids:   home_players
        },
        away: {
          name: away_team,
          pitcher_id:   away_pitcher_id,
          pitcher_name: away_pitcher_name,
          player_ids:   away_players
        }
      }
    end.compact
  end

  def fetch_player_stat(player_id)
    d = HTTParty.get("https://fantasydata.com/mlb/a-b-fantasy/#{player_id}", timeout: 10)
    Nokogiri::HTML(d.body).xpath("//*[@class='d-inline-block']")[1]
      &.children&.[](1)
      &.children&.[](7)
      &.children&.select { |x| x&.children&.first&.children&.first&.text == @proposal_date.year.to_s }
      &.first
  rescue => e
    puts "  player_stat #{player_id} failed: #{e.message.split("\n").first}"
    nil
  end

  def savant_lineups
    @savant_lineups ||= begin
      response = HTTParty.get(savant_games_url, timeout: 30)
      games = response.dig('dates', 0, 'games') || []
      puts "savant_lineups: #{games.length} games from MLB Stats API"
      games.map do |m|
        {
          id: m['gamePk'],
          home: {
            name:         m.dig('teams', 'home', 'team', 'name'),
            pitcher_id:   m.dig('teams', 'home', 'probablePitcher', 'id'),
            pitcher_name: m.dig('teams', 'home', 'probablePitcher', 'fullName')
          },
          away: {
            name:         m.dig('teams', 'away', 'team', 'name'),
            pitcher_id:   m.dig('teams', 'away', 'probablePitcher', 'id'),
            pitcher_name: m.dig('teams', 'away', 'probablePitcher', 'fullName')
          }
        }
      end
    rescue => e
      puts "savant_lineups failed: #{e.class} — #{e.message}"
      []
    end
  end

  # xERA + xwOBA
  def expected_stats_leaderboard
    @expected_stats_leaderboard ||= fetch_leaderboard(
      "https://baseballsavant.mlb.com/leaderboard/expected_statistics?type=pitcher&year=#{@proposal_date.year}&position=&team=&min=0&csv=true",
      'expected_statistics'
    )
  end

  # barrel% (brl_pa) + hard_hit% (ev95percent)
  def batted_ball_leaderboard
    @batted_ball_leaderboard ||= fetch_leaderboard(
      "https://baseballsavant.mlb.com/leaderboard/statcast?type=pitcher&year=#{@proposal_date.year}&position=&team=&min=0&csv=true",
      'batted_ball'
    )
  end

  def fetch_leaderboard(url, name)
    puts "Fetching #{name} leaderboard..."
    response = HTTParty.get(url, timeout: 30, headers: { 'User-Agent' => 'Mozilla/5.0' })
    rows = CSV.parse(response.body.encode('UTF-8', invalid: :replace, undef: :replace).gsub("\xEF\xBB\xBF", ''), headers: true)
    puts "  #{name}: #{rows.length} rows"
    rows.each_with_object({}) { |row, h| h[row['player_id'].to_s] = row }
  rescue => e
    puts "Failed to fetch #{name} leaderboard: #{e.class} — #{e.message}"
    {}
  end

  def pitcher_statcast(player_id)
    id = player_id.to_s
    { expected: expected_stats_leaderboard[id], batted_ball: batted_ball_leaderboard[id] }
  end

  def statcast_val(data, source, key)
    row = data[source]
    return 0.0 unless row && row[key]
    row[key].to_f
  end

  def games_url
    "https://fantasydata.com/mlb/daily-lineups?date=#{@proposal_date}"
  end

  def savant_games_url
    "https://statsapi.mlb.com/api/v1/schedule?sportId=1&date=#{@proposal_date}&hydrate=probablePitcher"
  end
end
