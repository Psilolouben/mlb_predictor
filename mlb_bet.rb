require 'httparty'
require 'pry'
require 'pry-nav'
require 'distribution'

GAMES_URL = 'https://fantasydata.com/MLB_Lineups/RefreshLineups'

def player_stats(id)
  HTTParty.post("https://fantasydata.com/MLB_Player/PlayerSeasonStats?sort=&page=1&pageSize=50&group=&filter=&playerid=#{id}&season=2024&scope=1")
end

def data
  HTTParty.post(GAMES_URL,
    body: {
      "filters": {
        "date": Date.today.to_s
      }
    }.to_json,
    headers: { 'Content-Type' => 'application/json' })
end

def export_to_csv(proposals)
  CSV.open("bet_proposals.csv", "w", col_sep: ';') do |csv|
    idx = 2
    csv << ['Team', 'Pitcher', 'Poss','', 'Prop']
    proposals.each do |game|
      csv << [
        game[:home] > game[:away] ? game[:home_team] : game[:away_team],
        game[:home] > game[:away] ? game[:home_pitcher] : game[:away_pitcher],
        [game[:home], game[:away]].max.to_s.gsub('.',','),
        '',
        "=(C#{idx}+D#{idx})/2"
      ]
      idx+=1
    end
  end;0
end

proposals = []

def simulate_match(match)
  expected_home_era = Distribution::Poisson.rng(match[:home_pitcher][:era])
  expected_away_era = Distribution::Poisson.rng(match[:away_pitcher][:era])
  home_runs =  match[:home_avg_rbi].map { |x| Distribution::Poisson.rng(x) }.sum
  away_runs =  match[:away_avg_rbi].map { |x| Distribution::Poisson.rng(x) }.sum

  {
    home_team: match[:home_team],
    away_team: match[:away_team],
    home: (home_runs + expected_away_era) / 2,
    away: (away_runs + expected_home_era) / 2,
    home_pitcher: match[:home_pitcher][:name],
    away_pitcher: match[:away_pitcher][:name]
  }
end

def extract_proposals(match)
  {
    home_team: match.first[:home_team],
    away_team: match.first[:away_team],
    home: (match.count { |x| x[:home] > x[:away] } / match.count.to_f) * 100,
    away: (match.count { |x| x[:home] < x[:away] } / match.count.to_f) * 100,
    avg_total_runs: match.sum { |x| x[:home] + x[:away] } / match.count.to_f,
    home_pitcher: match.first[:home_pitcher],
    away_pitcher: match.first[:away_pitcher],
  }
end

lineups = data.map do |m|
  {
    id: m['GameID'],
    home: { name: m['HomeTeam'], pitcher_id: m['HomeTeamProbablePitcherID'], pitcher_name: m.dig('HomeTeamProbablePitcherDetails','Name'), player_ids: m['HomeLineup'].map { |p| p['Player']['PlayerID'] }},
    away: { name: m['AwayTeam'], pitcher_id: m['AwayTeamProbablePitcherID'], pitcher_name: m.dig('AwayTeamProbablePitcherDetails','Name'),player_ids: m['AwayLineup'].map { |p| p['Player']['PlayerID'] }}
  }
end

stats = lineups.each_with_object([]) do |l, arr|
  puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."

  unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
    puts 'Pitcher not found, match will be skipped'
    next
  else
    puts "#{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"
  end

  home_pitcher_era = player_stats(l[:home][:pitcher_id]).dig('Data')&.first&.dig('EarnedRunAverage')

  away_pitcher_era = player_stats(l[:away][:pitcher_id]).dig('Data')&.first&.dig('EarnedRunAverage')

  puts "Warning!!! #{l[:home][:pitcher_name]} has no ERA" if home_pitcher_era&.zero?

  puts "Warning!!! #{l[:away][:pitcher_name]} has no ERA" if away_pitcher_era&.zero?

  arr <<
    {
      home_team: l[:home][:name],
      away_team: l[:away][:name],
      home_pitcher: {
        era: home_pitcher_era,
        name: l[:home][:pitcher_name]
        #avg_ko: player_stats(l[:home][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:home][:pitcher_id])['Data'].first['Games'].to_f
      },
      away_pitcher: {
        era: away_pitcher_era,
        name: l[:away][:pitcher_name]
        #avg_ko: player_stats(l[:away][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:away][:pitcher_id])['Data'].first['Games'].to_f
      },
      home_avg_rbi: l[:home][:player_ids].map { |rb| player_stats(rb)['Data'].first['RunsBattedIn'] / player_stats(rb)['Data'].first['Games'].to_f },
      away_avg_rbi: l[:away][:player_ids].map { |rb| player_stats(rb)['Data'].first['RunsBattedIn'] / player_stats(rb)['Data'].first['Games'].to_f }
    }
end

stats.each do |s|
  next unless s[:home_pitcher][:era] && s[:away_pitcher][:era]

  puts "Simulating games..."
  res = []
  15000.times do
    res << simulate_match(s)
  end

  final_results = res.select{ |x| x[:home] != x[:away]}

  a = extract_proposals(final_results)
  pp a
  proposals << a
end

export_to_csv(proposals)
