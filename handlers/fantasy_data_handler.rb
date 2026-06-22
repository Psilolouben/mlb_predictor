require_relative './base_handler.rb'

class FantasyDataHandler < BaseHandler
  MLB_API = 'https://statsapi.mlb.com/api/v1'.freeze

  def stats
    @batter_stats_cache = {}

    schedule_games.each_with_object([]) do |g, arr|
      home            = g.dig('teams', 'home')
      away            = g.dig('teams', 'away')
      home_team       = home.dig('team', 'name')
      away_team       = away.dig('team', 'name')
      home_pitcher_id = home.dig('probablePitcher', 'id')
      away_pitcher_id = away.dig('probablePitcher', 'id')
      home_pitcher_nm = home.dig('probablePitcher', 'fullName')
      away_pitcher_nm = away.dig('probablePitcher', 'fullName')
      home_lineup     = g.dig('lineups', 'homePlayers') || []
      away_lineup     = g.dig('lineups', 'awayPlayers') || []

      puts "Fetching stats for #{home_team} - #{away_team}..."

      if home_lineup.empty? || away_lineup.empty?
        puts "  Lineup not posted yet, skipping"
        next
      end

      unless home_pitcher_id && away_pitcher_id
        puts "  Pitcher not found, skipping"
        next
      end

      puts "  #{home_pitcher_nm} vs #{away_pitcher_nm}"

      home_row = pitcher_statcast(home_pitcher_id)
      away_row = pitcher_statcast(away_pitcher_id)

      home_pitcher_era  = statcast_val(home_row, :expected, 'xera')
      away_pitcher_era  = statcast_val(away_row, :expected, 'xera')
      home_pitcher_xwoba = statcast_val(home_row, :expected, 'est_woba')
      away_pitcher_xwoba = statcast_val(away_row, :expected, 'est_woba')
      home_pitcher_barrel = statcast_val(home_row, :batted_ball, 'brl_pa') / 100.0
      away_pitcher_barrel = statcast_val(away_row, :batted_ball, 'brl_pa') / 100.0
      home_pitcher_hard_hit = statcast_val(home_row, :batted_ball, 'ev95percent') / 100.0
      away_pitcher_hard_hit = statcast_val(away_row, :batted_ball, 'ev95percent') / 100.0

      puts "  Warning!!! #{home_pitcher_nm} has no xERA" if home_pitcher_era.zero?
      puts "  Warning!!! #{away_pitcher_nm} has no xERA" if away_pitcher_era.zero?

      home_batter_ids = home_lineup.map { |p| p['id'] }
      away_batter_ids = away_lineup.map { |p| p['id'] }

      arr << {
        home_team: home_team,
        away_team: away_team,
        home_pitcher: {
          era:          home_pitcher_era,
          k_rate:       0.0,
          bb_rate:      0.0,
          hard_hit_pct: home_pitcher_hard_hit,
          barrel_pct:   home_pitcher_barrel,
          whiff_pct:    0.0,
          xwoba:        home_pitcher_xwoba,
          name:         home_pitcher_nm,
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
          name:         away_pitcher_nm,
          era_warning:  away_pitcher_era.zero?
        },
        home_avg_rbi: home_batter_ids.filter_map { |id| batter_rbi_per_game(id) },
        away_avg_rbi: away_batter_ids.filter_map { |id| batter_rbi_per_game(id) }
      }
    end
  end

  def schedule_games
    url = "#{MLB_API}/schedule?sportId=1&date=#{@proposal_date}&hydrate=lineups,probablePitcher"
    puts "Fetching schedule from MLB API..."
    response = HTTParty.get(url, timeout: 30)
    games = response.dig('dates', 0, 'games') || []
    puts "#{games.length} games found"
    games
  rescue => e
    puts "Failed to fetch schedule: #{e.class} — #{e.message}"
    []
  end

  def batter_rbi_per_game(player_id)
    @batter_stats_cache[player_id] ||= begin
      url = "#{MLB_API}/people/#{player_id}/stats?stats=season&group=hitting&season=#{@proposal_date.year}"
      response = HTTParty.get(url, timeout: 15)
      splits = response.dig('stats', 0, 'splits') || []
      return nil if splits.empty?
      stat = splits.first['stat']
      rbi   = stat['rbi'].to_f
      games = stat['gamesPlayed'].to_f
      val = games.positive? ? rbi / games : nil
      val&.finite? && val > 0 && val < 1.5 ? val : nil
    rescue => e
      puts "  batter_rbi_per_game failed for #{player_id}: #{e.message}"
      nil
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
end
