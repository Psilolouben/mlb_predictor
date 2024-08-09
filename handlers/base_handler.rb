class BaseHandler

  def upload_to_bucket
    storage = Google::Cloud::Storage.new(
      project_id: "mlb-bet-predictor",
      credentials: "mlb-bet-predictor-b83d3bb4dce7.json"
    )
    bucket = storage.bucket("gcf-v2-uploads-944915810467-us-central1")
    a = bucket.create_file("bet_proposals.csv", "bet_proposals.csv", cache_control: 'max-age=0')
    a.public_url
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
end
