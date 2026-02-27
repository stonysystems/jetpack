import json
import re
import itertools
import csv
from collections import Counter

asia = {5, 6, 7, 10, 12, 13, 14}
euro = {4, 11, 15, 16, 17}
us = {0, 1, 2, 3}

servers = None

def load_latency_data(file_path):
    with open(file_path, 'r') as f:
        data = json.load(f)
    global servers
    servers = data['n_server']
    latency_matrix = [[0.0 for _ in range(servers)] for _ in range(servers)]
    for server_data in data['inter_server_latencies']:
        from_idx = int(re.search(r'server-(\d+)', server_data['from']).group(1))
        for to_server, latency in server_data['latencies'].items():
            to_idx = int(re.search(r'server-(\d+)', to_server).group(1))
            try:
                latency_value = float(latency.replace(' ms', ''))
            except ValueError:
                latency_value = float('inf')
            latency_matrix[from_idx][to_idx] = latency_value
    return latency_matrix


def print_latency_matrix(matrix):
    print("\nInter-server Latency Matrix (ms):")
    print("     ", end="")
    for i in range(len(matrix)):
        print(f" S{i}     ", end="")
    print()
    
    for i, row in enumerate(matrix):
        print(f"S{i}  ", end="")
        for latency in row:
            if latency == float('inf'):
                print("   N/A   ", end="")
            else:
                print(f"{latency:7.1f} ", end="")
        print()


def calc_jetpack(latency_mat, replicas, client):

    latencies_to_replicas = [latency_mat[client][i] for i in replicas if latency_mat[client][i] != float('inf')]
    assert len(latencies_to_replicas) >= 5
    sorted_latencies = sorted(latencies_to_replicas)

    return sorted_latencies[4]


def calc_raft(latency_mat, replicas, raft_leader, client):

    latencies_to_replicas = [latency_mat[raft_leader][i] for i in replicas if latency_mat[raft_leader][i] != float('inf')]
    assert len(latencies_to_replicas) >= 5
    sorted_latencies = sorted(latencies_to_replicas)

    return latency_mat[client][raft_leader] + sorted_latencies[2]


def calc_copilot(latency_mat, replicas, pilot, copilot, client):

    pilot_latencies_to_replicas = [latency_mat[pilot][i] for i in replicas if latency_mat[pilot][i] != float('inf')]
    assert len(pilot_latencies_to_replicas) >= 5
    sorted_pilot_latencies = sorted(pilot_latencies_to_replicas)

    copilot_latencies_to_replicas = [latency_mat[copilot][i] for i in replicas if latency_mat[copilot][i] != float('inf')]
    assert len(copilot_latencies_to_replicas) >= 5
    sorted_copilot_latencies = sorted(copilot_latencies_to_replicas)

    return min(latency_mat[client][pilot] + sorted_pilot_latencies[2], latency_mat[client][copilot] + sorted_copilot_latencies[2])


def calc_mencius(latency_mat, replicas, client):

    min_latency = 1e8

    for leader in replicas:

        latencies_to_replicas = [latency_mat[leader][i] for i in replicas if latency_mat[leader][i] != float('inf')]
        assert len(latencies_to_replicas) >= 5
        sorted_latencies = sorted(latencies_to_replicas)

        min_latency = min(min_latency, latency_mat[client][leader] + sorted_latencies[2])

    return min_latency


def analyze_replica_sets(matrix):
    n_servers = len(matrix)
    all_combinations = list(itertools.combinations(range(n_servers), 5))
    print(len(all_combinations))

    results = []
    
    for combo in all_combinations:

        asia_cnt = len(set(combo) & asia)
        euro_cnt = len(set(combo) & euro)
        us_cnt = len(set(combo) & us)

        if asia_cnt < 1 or asia_cnt > 2 or euro_cnt < 1 or euro_cnt > 2 or us_cnt < 1 or us_cnt > 2 or asia_cnt + euro_cnt + us_cnt < 5:
            continue
        
        for raft_copilot_leader in combo:

            for copilot_leader in combo:

                if copilot_leader == raft_copilot_leader:
                    continue
                
                if not ((raft_copilot_leader in us) or (copilot_leader in us)):
                    continue

                replicas = list(combo)
                combo_results = {
                    'replicas': [f"S{i}" for i in replicas],
                    'raft_copilot_leader': raft_copilot_leader,
                    'copilot_leader': copilot_leader,
                    'jetpack_latency': [],
                    'raft_latency': [],
                    'copilot_latency': [],
                    'mencius_latency': [],
                    'maximum_minimum_improvement': -1e8,
                    'maximum_minimum_improvement_id': None,
                    'minimum_minimum_improvement': 1e8,
                    'minimum_minimum_improvement_id': None,
                    'relu_improvement': [],
                    'top_relu_improvement': 0,
                }
                
                for i in range(n_servers):

                    jl = calc_jetpack(matrix, replicas, i)
                    rl = calc_raft(matrix, replicas, raft_copilot_leader, i)
                    cl = calc_copilot(matrix, replicas, raft_copilot_leader, copilot_leader, i)
                    ml = calc_mencius(matrix, replicas, i)
                    combo_results['jetpack_latency'].append(jl)
                    combo_results['raft_latency'].append(rl)
                    combo_results['copilot_latency'].append(cl)
                    combo_results['mencius_latency'].append(ml)

                    minimum_improvement = min(min((rl - jl) / rl, (cl - jl / cl)), (ml - jl) / ml) * 100

                    if minimum_improvement > combo_results['maximum_minimum_improvement']:
                        combo_results['maximum_minimum_improvement'] = minimum_improvement
                        combo_results['maximum_minimum_improvement_id'] = i
                    
                    if i in set(combo) and minimum_improvement < combo_results['minimum_minimum_improvement']:
                        combo_results['minimum_minimum_improvement'] = minimum_improvement
                        combo_results['minimum_minimum_improvement_id'] = i

                    relu_improvement = (rl - min(rl, jl)) / rl + (cl - min(cl, jl)) / cl + (ml - min(ml, jl)) / ml
                    if i in set(combo):
                        combo_results['top_relu_improvement'] += relu_improvement
                    else:
                        combo_results['relu_improvement'].append(relu_improvement)

                combo_results['top_relu_improvement'] += sum(sorted(combo_results['relu_improvement'], reverse=True)[:5])
                results.append(combo_results)
    
    return results


def print_analysis_summary(results):
    
    print(len(results))

    sorted_results = sorted(
        results,
        # key=lambda x: x['maximum_minimum_improvement'] if x['maximum_minimum_improvement'] is not None else float('-inf'),
        # key=lambda x: x['minimum_minimum_improvement'] if x['minimum_minimum_improvement'] is not None else float('-inf'),
        key=lambda x: x['top_relu_improvement'] if x['top_relu_improvement'] is not None else float('-inf'),
        reverse=True
    )

    global servers

    # Write to CSV
    with open('replica_analysis.csv', 'w', newline='') as csvfile:
        fieldnames = ['replicas', 'raft_copilot_leader', 'copilot_leader', 'maximum_minimum_improvement', 'maximum_minimum_improvement_id', 'minimum_minimum_improvement', 'minimum_minimum_improvement_id', 'top_relu_improvement']
        for i in range(servers):
            fieldnames.append(f'jetpack_latency_S{i}')
            fieldnames.append(f'raft_latency_S{i}')
            fieldnames.append(f'copilot_latency_S{i}')
            fieldnames.append(f'mencius_latency_S{i}')
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        
        writer.writeheader()
        for result in sorted_results[:500]:
            row = {
                'replicas': ','.join(result['replicas']),
                'raft_copilot_leader': f"{result['raft_copilot_leader']}",
                'copilot_leader': f"{result['copilot_leader']}",
                'maximum_minimum_improvement': f"{result['maximum_minimum_improvement']:.2f}",
                'maximum_minimum_improvement_id': f"{result['maximum_minimum_improvement_id']}",
                'minimum_minimum_improvement': f"{result['minimum_minimum_improvement']:.2f}",
                'minimum_minimum_improvement_id': f"{result['minimum_minimum_improvement_id']}",
                'top_relu_improvement': f"{result['top_relu_improvement']}",
            }
            for i in range(servers):
                row[f'jetpack_latency_S{i}'] = (f"{result['jetpack_latency'][i]:.2f}" 
                                                if result['jetpack_latency'][i] != float('inf') else 'inf')
                row[f'raft_latency_S{i}'] = (f"{result['raft_latency'][i]:.2f}" 
                                                    if result['raft_latency'][i] != float('inf') else 'inf')
                row[f'copilot_latency_S{i}'] = (f"{result['copilot_latency'][i]:.2f}" 
                                                if result['copilot_latency'][i] != float('inf') else 'inf')
                row[f'mencius_latency_S{i}'] = (f"{result['mencius_latency'][i]:.2f}" 
                                                    if result['mencius_latency'][i] != float('inf') else 'inf')
            writer.writerow(row)
    
    print("\nResults have been written to 'replica_analysis.csv'")


def main():
    file_path = "latency_results/latency_results_20250403_165744.json"
    
    try:
        latency_matrix = load_latency_data(file_path)
        print_latency_matrix(latency_matrix)
        
        analysis_results = analyze_replica_sets(latency_matrix)
        print_analysis_summary(analysis_results)
        
    except FileNotFoundError:
        print(f"Error: File '{file_path}' not found")
    except json.JSONDecodeError:
        print("Error: Invalid JSON format")
    except Exception as e:
        print(f"An error occurred: {str(e)}")


if __name__ == "__main__":
    main()