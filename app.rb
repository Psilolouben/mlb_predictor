require 'httparty'
require 'pry'
require 'pry-nav'
require 'distribution'
require 'date'
require 'json'
require 'csv'
require "google/cloud/storage"

GAMES_URL = 'https://fantasydata.com/MLB_Lineups/RefreshLineups'
ODDS_URL = 'https://www.novibet.gr/spt/feed/marketviews/location/v2/4324/4375810'

FunctionsFramework.http "main" do |request|
  proposals = []
  todays_odds = odds.compact
  lineups = data.map do |m|
    {
      id: m['GameID'],
      home: { name: m['HomeTeam'], pitcher_id: m['HomeTeamProbablePitcherID'], pitcher_name: m.dig('HomeTeamProbablePitcherDetails','Name'), player_ids: m['HomeLineup'].map { |p| p['Player']['PlayerID'] }},
      away: { name: m['AwayTeam'], pitcher_id: m['AwayTeamProbablePitcherID'], pitcher_name: m.dig('AwayTeamProbablePitcherDetails','Name'),player_ids: m['AwayLineup'].map { |p| p['Player']['PlayerID'] }}
    }
  end

  stats = lineups.each_with_object([]) do |l, arr|
    @cached_stats = {}
    puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."
    home_odd = todays_odds.find{|x| x[:home] == l[:home][:name] || x[:away] == l[:away][:name]}&.dig(:home_odd)
    away_odd = todays_odds.find{|x| x[:home] == l[:home][:name] || x[:away] == l[:away][:name]}&.dig(:away_odd)

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
          name: l[:home][:pitcher_name],
          era_warning: home_pitcher_era&.zero?
          #avg_ko: player_stats(l[:home][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:home][:pitcher_id])['Data'].first['Games'].to_f
        },
        away_pitcher: {
          era: away_pitcher_era,
          name: l[:away][:pitcher_name],
          era_warning: away_pitcher_era&.zero?
          #avg_ko: player_stats(l[:away][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:away][:pitcher_id])['Data'].first['Games'].to_f
        },
        home_avg_rbi: l[:home][:player_ids].map { |rb| player_stats(rb)['Data'].first['RunsBattedIn'] / player_stats(rb)['Data'].first['Games'].to_f },
        away_avg_rbi: l[:away][:player_ids].map { |rb| player_stats(rb)['Data'].first['RunsBattedIn'] / player_stats(rb)['Data'].first['Games'].to_f },
        home_odd:,
        away_odd:
      }
  end

  stats.each do |s|
    next unless s[:home_pitcher][:era] && s[:away_pitcher][:era]

    puts "Simulating games..."
    res = []
    15000.times do
      res << simulate_match(s).merge(s)
    end
    final_results = res.select{ |x| x[:home] != x[:away]}
    a = extract_proposals(final_results)
    pp a
    proposals << a
  end
  export_to_csv(proposals)
  "CSV file here -> #{upload_to_bucket}"
end

def player_stats(player_id)
  @cached_stats[player_id] || begin
    @cached_stats[player_id] =
      HTTParty.post("https://fantasydata.com/MLB_Player/PlayerSeasonStats?sort=&page=1&pageSize=50&group=&filter=&playerid=#{player_id}&season=2024&scope=1", timeout: 120)
    @cached_stats[player_id]
  end
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
    csv << ['Team', 'Pitcher', 'Poss', 'Avg. Runs', 'O75', 'O85', 'O95', 'Odd']

    proposals.each do |game|
      csv << [
        game[:home] > game[:away] ? "#{game[:home_team]}#{game[:home_pitcher][:era_warning] ? '*' : ''}" : "#{game[:away_team]}#{game[:away_pitcher][:era_warning] ? '*' : ''}",
        game[:home] > game[:away] ? game[:home_pitcher][:name] : game[:away_pitcher][:name],
        [game[:home], game[:away]].max.to_s.gsub('.',','),
        game[:avg_total_runs].to_s.gsub('.', ','),
        game[:o75].to_s.gsub('.', ','),
        game[:o85].to_s.gsub('.', ','),
        game[:o95].to_s.gsub('.', ','),
        (game[:home_odd].nil? || game[:away_odd].nil?) ?
          '' : (
            game[:home] > game[:away] ?
              (100.0/game[:home_odd]).to_s.gsub('.', ',') : (100.0/game[:away_odd]).to_s.gsub('.', ','))
        #"=(C#{idx}+D#{idx})/2"
      ]
      idx += 1
    end
  end;0
end

def simulate_match(match)
  expected_home_era = Distribution::Normal.rng(match[:home_pitcher][:era]).call
  expected_away_era = Distribution::Normal.rng(match[:away_pitcher][:era]).call
  home_runs =  match[:home_avg_rbi].map { |x| Distribution::Poisson.rng(x) }.sum
  away_runs =  match[:away_avg_rbi].map { |x| Distribution::Poisson.rng(x) }.sum

  {
    home_team: match[:home_team],
    away_team: match[:away_team],
    home: (home_runs + expected_away_era) / 2,
    away: (away_runs + expected_home_era) / 2,
    home_pitcher: match[:home_pitcher][:name],
    away_pitcher: match[:away_pitcher][:name],
    home_odd: match[:home_odd],
    away_odd: match[:away_odd]
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
    o75: (match.count { |x| (x[:home] + x[:away]) > 7.5 } / match.count.to_f) * 100,
    o85: (match.count { |x| (x[:home] + x[:away]) > 8.5 } / match.count.to_f) * 100,
    o95: (match.count { |x| (x[:home] + x[:away]) > 9.5 } / match.count.to_f) * 100,
    home_odd: match.first[:home_odd],
    away_odd: match.first[:away_odd]
  }
end

def upload_to_bucket
  storage = Google::Cloud::Storage.new(
    project_id: "mlb-bet-predictor",
    credentials: "mlb-bet-predictor-452effb0b17a.json"
  )
  bucket = storage.bucket("gcf-v2-uploads-944915810467-us-central1")
  a = bucket.create_file("bet_proposals.csv", "bet_proposals.csv", cache_control: 'max-age=0')
  a.public_url
end

def odds
  odds = HTTParty.get(ODDS_URL, timeout: 120)
  odds.first['betViews'].first['items'].map do |odd|
    next if odd['isLive']
    {
      home: odd['additionalCaptions']['competitor1'].split('(').first.split(' ').first,
      away: odd['additionalCaptions']['competitor2'].split('(').first.split(' ').first,
      home_odd: odd['markets'].first['betItems'].first['price'],
      away_odd: odd['markets'].first['betItems'].last['price']
    }
  end
end


