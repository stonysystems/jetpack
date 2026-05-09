def read_latency_file(file_path):
    """
    Read a file with latency data into a 2D array (15x15 matrix).

    The file is expected to contain 225 latency values either in one single line 
    or multiple lines without specific delimiters between rows.

    :param file_path: Path to the file containing the latency data.
    :return: A list of lists, where each sublist contains 15 latency values.
    """
    with open(file_path, 'r') as file:
        # Read all lines, strip spaces, and join into a single string
        all_data = ' '.join([line.strip() for line in file])
        # Split the data into individual latency values
        all_values = all_data.split()
        # Check if the data size matches 15x15 matrix
        if len(all_values) != 225:
            raise ValueError("Expected 225 latency values in the file.")

        # Create the 2D array
        latency_matrix = [all_values[i * 15:(i + 1) * 15] for i in range(15)]
    
    return latency_matrix

# Example usage
file_path = 'latency_results.txt'
try:
    latency_data = read_latency_file(file_path)
    print(latency_data)
except Exception as e:
    print(e)

