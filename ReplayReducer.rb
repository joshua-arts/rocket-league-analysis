=begin

Written by Joshua Arts for RL Analysis.

This code takes a large JSON file generated by Taylor Fausak's replay parser
Octane ( https://github.com/tfausak/octane ), reduces all the data into
meaningful data, then performs an analysis on that data to output a JSON file
containing stats that the game itself can't provide (like boost analysis,
possession numbers, etc).

If you see and missed calculations or errors, please let me know!

Also, lots of credit to Daniel Samuels. The way in which I read the Octane JSON
file and extracted that data was heavily inspired by the way he does it for
Rocket League Replays.

TODO:

lb positions
shot distance / speed
matchtype in extra data & base point values off it

more accurate boost data
fix boost_data in OT.
test if kickoffs still correct after 0 second goal.
test proximity to ball every frame (not sure if can do)
sub playing_players for player_cars.keys
make sure defense / offense numbers for sides of field aren't swapped
    essentially players always spend more time on defense.

=end

require 'json'

# - Helpers Methods - #

# Checks if an actor has a stat.
def check_for_stat(actor, stat)
    actor.has_key?(stat) ? actor[stat]['Value'] : 0
end

# Computes the points only score for a player.
def compute_points_score(actor)
    goals = check_for_stat(actor, 'TAGame.PRI_TA:MatchGoals')
    shots = check_for_stat(actor, 'TAGame.PRI_TA:MatchShots')
    assists = check_for_stat(actor, 'TAGame.PRI_TA:MatchAssists')
    saves = check_for_stat(actor, 'TAGame.PRI_TA:MatchSaves')
    (goals * 50) + (assists * 25) + (saves * 25) + (shots * 15)
end

# Determines a players team.
def find_player_team(octane_stats, name)
    octane_stats.each{ |stats, ind|
        if stats['Name']['Value'] == name then
            return stats['Team']['Value'] == 1 ? "orange" : "blue"
        end
    }
    raise "ERROR: Couldn't find player_stats for " + name
end

# Selects the closest value in list to the target.
# NOTE: Redo this method...

def select_closest_over(list, target)
    list.each{ |val|
        return val if val > target
    }
end

def select_closest(list, target)
    (list.map {|x| [(x.to_f - target).abs, x]}).min[1]
end

# Find the distance between positions a and b.
def distance(a, b)
    x = b['x'] - a['x']
    y = b['y'] - a['y']
    z = b['z'] - a['z']
    Math.sqrt((x ** 2) + (y ** 2) + (z ** 2))
end

# Takes a 2 element array and an element, returns the one you don't pass.
def opposite(arr, ind)
    return arr[1] if ind == arr[0]
    arr[0]
end

class ReplayReducer

    # Keys to extract data from the metadata.
    @@meta_data_keys = ['MaxChannels', 'Team0Score', 'Team1Score', 'PlayerName', 'KeyframeDelay',
                      'MaxReplaySizeMB', 'NumFrames', 'MatchType', 'MapName', 'ReplayName',
                      'PrimaryPlayerTeam', 'Id', 'TeamSize', 'RecordFPS', 'Date']

    # Keys to extract data from player_stats.
    @@player_data_keys = ['Goals', 'Saves', 'Shots', 'Assists', 'Score', 'Team', 'bBot', 'Name']

    # WHY NO CAPITAL F PSYONIX!?
    # Keys to extract data from the goals.
    @@goal_data_keys = ['frame', 'PlayerName', 'PlayerTeam']

    # ground, crossbar, aerial
    @@height_bounds = [120, 250, 600]

    def initialize(oct_json)
        @file = File.read(file_name)
        @data = JSON.parse(@file)
        #@data = oct_json

        # Divide up the important data segments.
        @metadata = @data['Metadata']
        @player_stats = @metadata['PlayerStats']['Value']
        @goals = @metadata['Goals']['Value']
        @frames = @data['Frames']

        # Maps player uuID's to their player actor ID.
        @uuID_to_player_id = {}

        # Stores position_data for all important actors, and the ball.
        @position_data = {}

        # Stores the frames in which each player is closest to the ball.
        @frames_closest_raw = []
        @frames_closest = {}

        # Stores the various types of actors we find on each frame.
        @actors = {}
        @player_actors = {}
        @position_actors = {}

        # Maps player car objects to player id's.
        @player_cars = {}

        # Maps team data to their team ID in actors.
        @team_info = {}

        # Maps the current frame to the players boost value.
        @boost_data = {}
        @unknown_boost_data = {}
        @time_boost_data = {}
        @boost_pickups_raw = []

        # Maps current frame to the time remaining on the clock.
        @time_map = {}
        @time_position_data = {}

        # Store camera settings.
        @camera_settings = {}

        # Store posession.
        @posession_map = {}

        # JSON Object to store the important_data
        @important_data = {'metadata' => {},
                          'player_data' => {},
                          'team_data' => {
                              'orange' => {},
                              'blue' => {}
                          },
                          'goal_data' => {},
                          'extra_data' => {}
                          }

        # Extra data needed in analysis.
        # NOTE: Might be able to be local to get_frames()?
        @ball_hit = false
        @ball_spawned = false
        @cars_frozen = false
        @ball = nil
        @ball_actor_id = nil

        # Needed extra data.
        @overtime = false
        @kickoff_time_delay = 2
        @orange_kickoffs = @blue_kickoffs = 0

        @goal_frames = []
        @null_frames = [[],[]]
    end

    def to_s
        JSON.pretty_generate(@important_data)
    end

    def octane_json
        JSON.pretty_generate(@data)
    end

    def get_important_data
        @important_data
    end

    def reduce
        get_metadata()
        get_goals()
        get_frames()
    end

    # Read replay metadata.
    def get_metadata()
        @@meta_data_keys.each{ |key|
            @important_data['metadata'][key] = (@metadata[key]) ? @metadata[key]['Value'] : 0
        }
    end

    # Read replay goal data.
    def get_goals()
        @goals.each_with_index{ |goal, ind|
            goal_data = {}
            @@goal_data_keys.each{ |key|
                goal_data[key] = goal[key]['Value']
            }
            @important_data['goal_data'][ind] = goal_data
        }
    end

    # Read replay frame data (positions, boost data, etc).
    def get_frames()
        @frames.each_with_index{ |frame, i|

            # Create new frame instances for position object.
            @position_data[i] = {}

            ball_hit = false
            ball_spawned = false

            lowest_dist = 2000000
            lowest_dist_player = nil

            # Get new actors.
            spawned = frame['Spawned'] if frame['Spawned']

            # Get updated actors.
            updated = frame['Updated'] if frame['Updated']

            # Get deleted actors.
            deleted = frame['Destroyed'] if frame['Destoryed']

            handle_spawned_actors(spawned, i) if spawned
            handle_updated_actors(updated, i) if updated
            handle_deleted_actors(deleted, i) if deleted
            handle_merged_actors(spawned.merge(updated), i)
        }
    end

    def handle_spawned_actors(spawned, frame)
        spawned.each{ |key, s_actor|

            # Add the actor since it just spawned.
            @actors[key] = s_actor if !@actors.has_key?(key)

            # TODO: can this be moved to search_actors()
            if s_actor.has_key?("Engine.Pawn:PlayerReplicationInfo") then
                player_actor_id = s_actor['Engine.Pawn:PlayerReplicationInfo']['Value']['Int']
                @player_cars[player_actor_id] = key
            end

            # Might always be true? Doesn't hurt to check.
            if s_actor.has_key?('Class') then
                # Player join actor.
                if s_actor['Class'] == "TAGame.PRI_TA" then
                    @player_actors[key] = s_actor
                    # NOTE: Might not be needed.
                    @player_actors[key]['join_frame'] = frame
                end

                # Ball spawned actor.
                if s_actor['Class'] == "TAGame.Ball_TA" then
                    ball_spawned = true
                end

                # Team info actor.
                if s_actor['Class'] == 'TAGame.Team_Soccar_TA' then
                    @team_info[key] = s_actor['Name']
                end
            end
        }
    end

    def handle_updated_actors(updated, frame)
        updated.each{ |key, u_actor|

            # Make sure there are changes in the updated actor.
            if (@actors[key] != u_actor) then

                # Merge existing actor with changes.
                @actors[key] = @actors[key].merge(u_actor)

                if @player_actors.has_key?(key) then
                    @player_actors[key] = @actors[key]
                end
            end

            if u_actor.has_key?("Engine.Pawn:PlayerReplicationInfo") then
                player_actor_id = u_actor['Engine.Pawn:PlayerReplicationInfo']['Value']['Int']
                @player_cars[player_actor_id] = key
            end
        }
    end

    def handle_deleted_actors(deleted, frame)
        if deleted then
            deleted.each{ |key, d_actor|
                @actors.delete(key) if @actors.has_key?(key)
                # NOTE: Also potentially uneeded.
                @player_actors[key]['leave_frame'] = frame if @player_actors.has_key?(key)
            }
        end
    end

    def handle_merged_actors(merged, frame)
        real_player = nil

        # Go through all actors that have been affected during this frame.
        merged.each{ |key, actor_data|
            # Check for position data.
            if actor_data.has_key?('TAGame.RBActor_TA:ReplicatedRBState') then
                @position_actors[key] = actor_data['TAGame.RBActor_TA:ReplicatedRBState']['Value']['Position']

                @player_cars.each{ |player_key, car_key|
                    if car_key == key then
                        real_player = player_key
                        break
                    end
                }

                real_player = "ball" if @player_cars.key(key) == nil

                pos_data = actor_data['TAGame.RBActor_TA:ReplicatedRBState']['Value']['Position']
                rot_data = actor_data['TAGame.RBActor_TA:ReplicatedRBState']['Value']['Rotation']

                # Create new position instance for player at frame.
                pos_instance = {
                    'id' => real_player,
                    'x' => pos_data[0],
                    'y' => pos_data[1],
                    'z' => pos_data[2],
                    'yaw' => rot_data[0],
                    'pitch' => rot_data[1],
                    'roll' => rot_data[2]
                }

                @position_data[frame][real_player] = pos_instance

            end

            if actor_data.has_key?('TAGame.CarComponent_Boost_TA:ReplicatedBoostAmount') then
                boost_value = actor_data['TAGame.CarComponent_Boost_TA:ReplicatedBoostAmount']['Value']
                raise "ERROR: Boost value is out of bounds." if boost_value < 0 or boost_value > 255

                @boost_data[key] = {} if !@boost_data.has_key?(key)

                if !@actors[key].has_key?('TAGame.CarComponent_TA:Vehicle') then

                    @unknown_boost_data[key] = {} if !@unknown_boost_data.has_key?(key)
                    @unknown_boost_data[key][frame] = boost_value

                else

                    # Find the car that the boost data belongs to.
                    car_id = @actors[key]['TAGame.CarComponent_TA:Vehicle']['Value']['Int']

                    player_id = @player_cars.key(car_id.to_s)

                    @boost_data[player_id] = {} if !@boost_data.has_key?(player_id)

                    @boost_data[player_id][frame] = boost_value

                    # Get floating data.
                    if @unknown_boost_data.has_key?(key) then
                        @unknown_boost_data[key].each{ |f_ind, boost|
                            @boost_data[player_id][f_ind] = boost
                        }
                        @unknown_boost_data.delete(key)
                    end

                end

            end

            if actor_data.has_key?('TAGame.CameraSettingsActor_TA:ProfileSettings') then
                if @actors[key]['Class'] == 'TAGame.CameraSettingsActor_TA' then
                    p_id = actor_data['TAGame.CameraSettingsActor_TA:PRI']['Value']['Int']
                    #@actors[p_id]['TAGame.PRI_TA:CameraSettings'] = actor_data['TAGame.CameraSettingsActor_TA:ProfileSettings']['Value']
                    @camera_settings[p_id] = actor_data['TAGame.CameraSettingsActor_TA:ProfileSettings']['Value']
                end
            end

            # This only occurs when the ball has changed possession.
            if actor_data.has_key?('TAGame.Ball_TA:HitTeamNum') then
                #in_possession = actor_data['TAGame.Ball_TA:HitTeamNum']['Value']
                @posession_map[frame] = actor_data['TAGame.Ball_TA:HitTeamNum']['Value']
            end

            search_actors(actor_data, frame)
        }

        # NOTE: Add all this to a function but I doon't think we need it.
        @ball_actor_id = nil
        @ball = nil
        @ball_hit = false

        # Find the ball.
        @actors.each{ |key, actor_data|
            if actor_data['Class'] == "TAGame.Ball_TA" then
                @ball_actor_id = key
                @ball = actor_data
                break
            end
        }

        # Get data from the ball if it has changed.
        # NOTE: Remove this velocity stuff?
        old_velocity = 0
        if(@ball and @ball.has_key?('TAGame.RBActor_TA:ReplicatedRBState')) then
            new_velocity = @ball['TAGame.RBActor_TA:ReplicatedRBState']['Value']['AngularVelocity']

            ball_hit = true if new_velocity != old_velocity
            old_velocity = new_velocity

        end

    end

    # Search for specific actors that contain data we need to keep track of.
    def search_actors(actor_data, frame)
        # Map frames to timer.
        if actor_data.has_key?('TAGame.GameEvent_Soccar_TA:SecondsRemaining') then
            @time_map[frame] = actor_data['TAGame.GameEvent_Soccar_TA:SecondsRemaining']['Value']
        end

        # Detrmine current state at current frame.
        if actor_data.has_key?('TAGame.GameEvent_TA:ReplicatedGameStateTimeRemaining') then
            if actor_data['TAGame.GameEvent_TA:ReplicatedGameStateTimeRemaining']['Value'] == 3 then
                @cars_frozen = true
            elsif actor_data['TAGame.GameEvent_TA:ReplicatedGameStateTimeRemaining']['Value'] == 0 then
                @cars_frozen = false
            end
        end

        # Get server name.
        if actor_data.has_key?('Engine.GameReplicationInfo:ServerName') then
            @important_data['metadata']['ServerName'] = actor_data['Engine.GameReplicationInfo:ServerName']['Value']
        end

        # Get max team size.
        if actor_data.has_key?('TAGame.GameEvent_Team_TA:MaxTeamSize') then
            @important_data['extra_data']['Max_Team_Size'] = actor_data['TAGame.GameEvent_Team_TA:MaxTeamSize']['Value']
        end

        if actor_data.has_key?('ProjectX.GRI_X:ReplicatedGamePlaylist') then
            @important_data['extra_data']['Playlist'] = actor_data['ProjectX.GRI_X:ReplicatedGamePlaylist']['Value']
        end
    end

    # - Analysis Methods - #

    def analyze

        # If the clock has 1 seconds twice, we went into overtime.
        @overtime = (@time_map.values.count(1) > 1)
        @important_data['extra_data']['Overtime'] = @overtime

        # A list a players who have cars (excludes spectators).
        playing_players = @player_cars.keys

        playing_players.each{ |player_id|
            @player_actors.each{ |key, actor|
                if key.to_i == player_id.to_i then
                    @uuID_to_player_id[key] = actor['Engine.PlayerReplicationInfo:UniqueId']['Value']['Remote']['Value']
                    break
                end
            }
        }

        record_time()

        # Extracts data from the actors and records for each playing player.
        record_player_data(playing_players)

        # Record boost data (avg boost) for each player.
        record_boost_data(playing_players)

        # Map the ball position to the clock.
        map_position_over_time()

        # Record position and distance data on the goals.
        record_goal_data()

        # Find the frames where they are not playing.
        find_null_frames()

        # Record the amount of time each player is in each zone, as well as the ball.
        record_zone_time()

        # Determine who won each kickoff.
        record_kickoffs()

        # Calculate closest player to the ball at each second.
        record_ball_proximity()

        # Determine who scored the game-winning goal.
        find_game_winning_goal()

        # Determine who got MVP.
        find_mvp()

        # Record team data.
        record_team_data()

        # Record camera settings.
        record_camera_settings()
    end

    def record_time()
        @important_data['metadata']['MatchTime'] = @time_map.keys.length - 1
    end

    def record_player_data(playing_players)
        @player_actors.each{ |key, actor|
            if playing_players.include?(key.to_i) then
                player_data = {
                    'Name' => actor['Engine.PlayerReplicationInfo:PlayerName']['Value'],
                    'Score' => check_for_stat(actor, 'TAGame.PRI_TA:MatchScore'),
                    'Goals' => check_for_stat(actor, 'TAGame.PRI_TA:MatchGoals'),
                    'Shots' => check_for_stat(actor, 'TAGame.PRI_TA:MatchShots'),
                    'Assists' => check_for_stat(actor, 'TAGame.PRI_TA:MatchAssists'),
                    'Saves' => check_for_stat(actor, 'TAGame.PRI_TA:MatchSaves'),
                    'Points_Score' => compute_points_score(actor),
                    'Play_Score' => check_for_stat(actor, 'TAGame.PRI_TA:MatchScore') - compute_points_score(actor),
                    'ID' => @uuID_to_player_id[key],
                    'Team' => find_player_team(@player_stats, actor['Engine.PlayerReplicationInfo:PlayerName']['Value']),
                    'Car' => actor['TAGame.PRI_TA:ClientLoadouts']['Value']['Loadout1']['Value']['Body']['Name']}
                @important_data['player_data'][player_data['ID']] = player_data
            end
        }
    end

    def record_boost_data(playing_players)
        # Clean spectators and non playing players from boost data.
        @boost_data.each{ |id, boost_obj|
            @boost_data.delete(id) unless playing_players.include?(id)
        }

        mapped_boost_data = {}

        # Record boost data by player.
        @player_actors.each{ |key, actor|
            # Ignore spectators and such.
            if @boost_data.has_key?(key.to_i) then
                mapped_boost_data[@uuID_to_player_id[key]] = @boost_data[key.to_i]
            end
        }

        # The boost data has already been mapped to players, now we map it to the clock.
        # NOTE: Seems to be not mapping all the boost data correctly.
        mapped_boost_data.each{ |uuID, b_data|
            temp_data = {}
            b_data.each{ |frame, boost|
                time_key = select_closest(@time_map.keys, frame)
                temp_data[@time_map[time_key]] = boost
            }
            @time_boost_data[uuID] = temp_data
        }

        # Calculate average boost.
        uuIDS = mapped_boost_data.keys
        inc = 0
        @time_boost_data.each{ |player_platform_id, boost_set|
            avg_boost_ratio = (boost_set.values.inject(0){|sum,x| sum + x } / boost_set.values.length)
            avg_boost = ((avg_boost_ratio / 255.0) * 100).round
            @important_data['player_data'][uuIDS[inc]]['AVG_Boost'] = avg_boost
            inc += 1
        }

        # NOTE: Uncomment this to add boost_data to the JSON.
        #@important_data['boost_data'] = mapped_boost_data

        mapped_boost_data.each{ |uuID, b_data|
            temp_data = {}
            b_data.each{ |frame, boost|
                time_key = select_closest(@time_map.keys, frame)
                temp_data[@time_map[time_key]] = boost
            }
            @time_boost_data[uuID] = temp_data
        }
    end

    def map_position_over_time()
        overtime_on = false
        @position_data.each{ |frame, p_data|
            time_key = select_closest(@time_map.keys, frame)
            if overtime_on then
                @time_position_data[0 - @time_map[time_key]] = p_data
            else
                @time_position_data[@time_map[time_key]] = p_data
            end
            @time_position_data[@time_map[time_key]] = p_data
            overtime_on = true if @time_map[time_key] == 0
        }
    end

    def record_zone_time()

        position_frames = {}
        height_frames = {}
        zone_frames = {}
        curr_posession = orange_posession = blue_posession = non_nill = 0

        (@player_cars.keys << 'ball').each{ |key|
            position_frames[key] = {'orange' => 0, 'blue' => 0}
            height_frames[key] = {'low' => 0, 'medium' => 0, 'high' => 0, 'count' => 0}
            zone_frames[key] = {'orange' => 0, 'blue' => 0, 'midfield' => 0}
        }

        @position_data.each{ |frame, pos_data|
            next if pos_data == nil
            pos_data.each{ |data_id, data|
                #data_id = data['id']
                if position_frames.has_key?(data_id) then
                    if data['y'] > 0 then
                        position_frames[data_id]['orange'] = position_frames[data_id]['orange'] + 1
                    elsif data['y'] < 0 then
                        position_frames[data_id]['blue'] = position_frames[data_id]['blue'] + 1
                    end

                    # NOTE: Switch from 1666.665 to 1800.
                    if data['y'] > 2000 then
                        zone_frames[data_id]['orange'] = zone_frames[data_id]['orange'] + 1
                    elsif data['y'] < -2000 then
                        zone_frames[data_id]['blue'] = zone_frames[data_id]['blue'] + 1
                    else
                        zone_frames[data_id]['midfield'] = zone_frames[data_id]['midfield'] + 1
                    end

                    if data['z'] > @@height_bounds[0] then
                        height_frames[data_id]['low'] = height_frames[data_id]['low'] + 1
                        if data['z'] > @@height_bounds[1] then
                            height_frames[data_id]['medium'] = height_frames[data_id]['medium'] + 1
                            if data['z'] > @@height_bounds[2] then
                                height_frames[data_id]['high'] = height_frames[data_id]['high'] + 1
                            end
                        end
                    end
                    height_frames[data_id]['count'] = height_frames[data_id]['count'] + 1
                end
            }

            # Might as well do posession while we're looping.
            curr_posession = @posession_map[frame] if @posession_map.has_key?(frame)
            if !is_null_frame(frame) then
                if curr_posession == 0 then
                    orange_posession = orange_posession + 1
                else
                    blue_posession = blue_posession + 1
                end
                non_nill = non_nill + 1
            end
        }

        team_short = @important_data['team_data']
        team_short['orange']['Posession'] = ((orange_posession / non_nill.to_f)* 100).round(2)
        team_short['blue']['Posession'] = ((blue_posession / non_nill.to_f) * 100).round(2)

        teams = ['orange','blue']
        p_short = @important_data['player_data']
        t_short = @important_data['team_data']
        e_short = @important_data['extra_data']

        position_frames.each{ |player_id, frame_data|
            num_frames = frame_data.values[0] + frame_data.values[1]
            if player_id != 'ball' then
                uuID = @uuID_to_player_id[player_id.to_s]
                player_team = p_short[uuID]['Team']
                p_short[uuID][opposite(teams, player_team).capitalize + '_Side_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data[opposite(teams, player_team)]).round(2)
                p_short[uuID][player_team.capitalize + '_Side_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data[player_team]).round(2)
                #p_short[uuID]['Attack_%'] = ((frame_data[opposite(teams, player_team)].to_f / num_frames) * 100.0).round(2)
                #p_short[uuID]['Defense_%'] = ((frame_data[player_team].to_f / num_frames) * 100.0).round(2)
            else
                ['orange', 'blue'].each_with_index{ |team, i|
                    #t_short[team]['Ball_' + opposite(teams, team).capitalize + '_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data[team]).round(2)
                    #t_short[team]['Ball_' + team.capitalize + '_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data[opposite(teams, team)]).round(2)
                    #t_short[team]['Attack_%'] = ((frame_data[team].to_f / num_frames) * 100.0).round(2)
                    #t_short[team]['Defense_%'] = ((frame_data[opposite(teams, team)].to_f / num_frames) * 100.0).round(2)
                    e_short['Ball_' + team.capitalize + '_Side'] = ((@time_map.keys.length / num_frames.to_f) * frame_data[opposite(teams, team)]).round(2)
                }
            end
        }

        height_frames.each{ |object_id, frame_data|
            if object_id == 'ball' then
                e_short['Ball_Airtime_Low'] = ((@time_map.keys.length / frame_data['count'].to_f) * frame_data['low']).round(2)
                e_short['Ball_Airtime_Medium'] = ((@time_map.keys.length / frame_data['count'].to_f) * frame_data['medium']).round(2)
                e_short['Ball_Airtime_High'] = ((@time_map.keys.length / frame_data['count'].to_f) * frame_data['high']).round(2)
            else
                uuID = @uuID_to_player_id[object_id.to_s]
                p_short[uuID]['Airtime_Low'] = ((@time_map.keys.length / frame_data['count'].to_f) * frame_data['low']).round(2)
                p_short[uuID]['Airtime_Medium'] = ((@time_map.keys.length / frame_data['count'].to_f) * frame_data['medium']).round(2)
                p_short[uuID]['Airtime_High'] = ((@time_map.keys.length / frame_data['count'].to_f) * frame_data['high']).round(2)
            end
        }

        #Orange_Zone_Time
        #Blue_Zone_Time
        #Midfield_Time
        zone_frames.each{ |object_id, frame_data|
            num_frames = frame_data.values[0] + frame_data.values[1] + frame_data.values[2]
            if object_id == 'ball' then
                e_short['Ball_Orange_Zone'] = ((@time_map.keys.length / num_frames.to_f) * frame_data['orange']).round(2)
                e_short['Ball_Blue_Zone'] = ((@time_map.keys.length / num_frames.to_f) * frame_data['blue']).round(2)
                e_short['Ball_Midfield'] = ((@time_map.keys.length / num_frames.to_f) * frame_data['midfield']).round(2)
            else
                uuID = @uuID_to_player_id[object_id.to_s]
                p_short[uuID]['Orange_Zone_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data['orange']).round(2)
                p_short[uuID]['Blue_Zone_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data['blue']).round(2)
                p_short[uuID]['Midfield_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_data['midfield']).round(2)
            end
        }
    end

    def tally_kickoff(second)
        if !@time_position_data[second].has_key?('ball') then
            raise "ERROR: Couldn't find ball at clock time " + second.to_s
        end
        if @time_position_data[second]['ball']['y'] > 0 then
            @blue_kickoffs = @blue_kickoffs + 1
        elsif @time_position_data[second]['ball']['y'] < 0 then
            @orange_kickoffs = @orange_kickoffs + 1
        else
            raise "ERROR: Ball position still zero when checking kickoff result."
        end
    end

    def record_kickoffs()
        goals_to_check = @important_data['goal_data'].values

        # Exclude last overtime goal if overtime occured.
        goals_to_check.pop if @overtime

        goals_to_check.each{ |data|
            # TODO: Needs to be seconds closest without going over...
            # Find the second to check position.
            kickoff_check = (@time_map[select_closest(@time_map.keys, data['frame'])] - @kickoff_time_delay)
            if(@time_position_data.has_key?(kickoff_check)) then
                tally_kickoff(kickoff_check)
            # Not sure if I need to error here. Should just ignore OT kickoff?
            else
                raise "ERROR: Can't find position data for second after kickoff."
            end
        }

        # NOTE: Can you score in a second? If so I need to check here then...

        # Tally the first kickoff a second after the faceoff.
        if @time_position_data.has_key?(299) then
            tally_kickoff(299)
        end

        # Tally the overtime kickoff a second after the faceoff if it happened.
        if @overtime && @time_position_data.has_key?(-1) then
            tally_kickoff(-1)
        end

        # Record total kickoffs in extra_data.
        @important_data['extra_data']['Kickoffs'] = @orange_kickoffs + @blue_kickoffs
        @important_data['team_data']['orange']['Kickoff_Wins'] = @orange_kickoffs
        @important_data['team_data']['blue']['Kickoff_Wins'] = @blue_kickoffs
    end

    def record_camera_settings()
        @camera_settings.each{ |p_id, settings|
            if @uuID_to_player_id.has_key?(p_id.to_s) then
                uuID = @uuID_to_player_id[p_id.to_s]
                if @important_data['player_data']['orange'].has_key?(uuID) then
                    @important_data['player_data']['orange'][uuID]['Camera'] = settings
                elsif @important_data['player_data']['blue'].has_key?(uuID) then
                    @important_data['player_data']['blue'][uuID]['Camera'] = settings
                end
            end
        }
    end

    def record_ball_proximity()
        # TODO: Make it so if the play doesn't have position data at that second, use last second.
        @time_position_data.each{ |frame, data|
            ball_points = nil
            low = 20000000;
            low_player = nil

            # Find the ball points at that frame.
            data.each{ |key, set|
                if key == "ball" then
                    ball_points = set
                    break
                end
            }

            next if ball_points == nil

            data.each{ |key, set|
                if key != "ball" then
                    dist = distance(set, ball_points)

                    if dist < low then
                        low = dist
                        low_player = key
                    end
                end
            }

            @player_actors.each{ |key, actor|
                if key.to_i == low_player.to_i then
                    @frames_closest_raw << low_player
                    break
                end
            }
        }
        # Count the closest player data and add it.
        #@frames_closest_raw.each{ |player_id|
        #    data_id = @uuID_to_player_id[player_id.to_s]
        #    @important_data['player_data'][data_id]['Frames_Closest'] = 0 unless @important_data['player_data'][data_id].has_key?('Frames_Closest')
        #    @important_data['player_data'][data_id]['Frames_Closest'] = @important_data['player_data'][data_id]['Frames_Closest'] + 1
        #}

        # Record as a percentage.
        #@important_data['player_data'].each{ |uuID, player|
        #    player['Closest_Percent'] = ((player['Frames_Closest'].to_f / @frames_closest_raw.length) * 100.0).round
        #}
    end

    def find_game_winning_goal()
        team_one = team_two = 0
        even = true
        gwg_name = ""

        @important_data['goal_data'].each{ |goal_num, goal_info|
            gwg_name = goal_info['PlayerName'] if even
            if goal_info['PlayerTeam'] == "1" then
                team_one = team_one + 1
            else
                team_two = team_two + 1
            end
            even = (team_one == team_two)
        }

        @important_data['extra_data']['GWG_Name'] = gwg_name
        # TODO: Add GWG by ID.

    end

    def find_mvp()
        score_data = {}
        @important_data['player_data'].each{ |player_num, player_info|
            score_data[player_info['ID']] = player_info['Score']
        }

        # TODO: Deal with two players having the same score (by goals, assists, etc.)
        # make sure max player is on winning team.

        mvp_id = score_data.key(score_data.values.max)

        @important_data['player_data'].each{ |player_num, player_info|
            player_info['MVP'] = (mvp_id == player_num)
        }

        @important_data['extra_data']['MVP_Name'] = @important_data['player_data'][mvp_id]['Name']
        @important_data['extra_data']['MVP_ID'] = mvp_id
    end

    def record_team_data()
        orange = {}
        blue = {}
        @important_data['player_data'].each{ |uuID, player|
            if player['Team'] == 'orange' then
                orange[uuID] = player
            else
                blue[uuID] = player
            end
        }
        @important_data['player_data'] = {'orange' => orange, 'blue' => blue}

        # Get team stats...
        num_seconds = @time_map.keys.length - 1
        @important_data['player_data'].each{ |team, players_by_team|
            team_score = team_boost = team_goals = team_assists = team_saves = team_shots = 0
            team_points_score = team_play_score = team_possession = team_orange_zone = 0
            team_blue_zone = team_midfield = team_air_time = 0
            players_by_team.each{ |uuID, player|
                team_score += player['Score']
                team_boost += player['AVG_Boost']
                team_goals += player['Goals']
                team_assists += player['Assists']
                team_saves += player['Saves']
                team_shots += player['Shots']
                team_points_score += player['Points_Score']
                team_play_score += player['Play_Score']
                #team_possession += player['Frames_Closest']
                team_orange_zone += player['Orange_Zone_Time']
                team_blue_zone += player['Blue_Zone_Time']
                team_midfield += player['Midfield_Time']
                team_air_time += player['Airtime_Low']
            }
            short = @important_data['team_data'][team]
            short['Score'] = team_score
            short['AVG_Score'] = (team_score / 3).round
            short['AVG_Boost'] = (team_boost / 3).round
            short['Goals'] = team_goals
            short['Assists'] = team_assists
            short['Saves'] = team_saves
            short['Shots'] = team_shots
            short['Points_Score'] = team_points_score
            short['Play_Score'] = team_play_score
            #short['Frames_Closest'] = team_possession
            #short['Closest_Percent'] = ((team_possession.to_f / @frames_closest_raw.length) * 100.0).round
            short['Orange_Zone_Time'] = team_orange_zone.round(2)
            short['Blue_Zone_Time'] = team_blue_zone.round(2)
            short['Midfield_Time'] = team_midfield.round(2)
            short['Air_Time'] = team_air_time.round(2)
        }
    end

    # Record ball position at frame of goal.
    def record_goal_data()
        @important_data['goal_data'].each{ |num, goal|
            @goal_frames << goal['frame']
            if @position_data[goal['frame']].has_key?('ball') then
                pos_data = @position_data[goal['frame']]['ball']
            else
                # Rare case where the ball doesn't exist at the logged ball frame.
                # Should be able to just go back a frame, but need to test to make
                # sure this always works.
                pos_data = @position_data[goal['frame'].to_i - 1]['ball']
            end
            goal["Position"] = {'x' => pos_data['x'],
                                'y' => pos_data['y'],
                                'z' => pos_data['z']}
        }
    end

    def find_null_frames()
        @goal_frames.each{ |frame|
            f = select_closest_over(@time_map.keys, frame)
            @null_frames[0] << frame
            @null_frames[1] << f
        }
    end

    def is_null_frame(frame)
        num_check = @null_frames.length
        num_check = num_check - 1 if @overtime
        num_check.times{ |i|
            if @null_frames[0][i] && @null_frames[1][i] then
                return true if frame > @null_frames[0][i] && frame < @null_frames[1][i]
            end
        }
        false
    end

end

# - Read Data - #

replay = ReplayReducer.new('./res.json')
replay.reduce

# - Analyze Data - #

replay.analyze
puts replay.to_s
puts replay.octane_json
