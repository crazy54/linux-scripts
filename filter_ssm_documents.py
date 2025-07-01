import argparse
import json
import logging
import re
import sys

# Attempt to import Boto3 and handle if it's missing
try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError, PartialCredentialsError
    BOTO3_AVAILABLE = True
except ImportError:
    BOTO3_AVAILABLE = False

# --- Configuration ---
DEFAULT_OLD_RUNTIMES = ["python3.9", "python3.8", "python3.7", "python3.6", "python2.7"]
DEFAULT_INPUT_FILENAME = "ssm_automations_to_update.txt"
DEFAULT_OUTPUT_FILENAME = "ssm_automations_filtered.txt"

# --- Logging Setup ---
logger = logging.getLogger(__name__)

def setup_logging(log_level_str):
    """Configures logging for the script."""
    numeric_level = getattr(logging, log_level_str.upper(), None)
    if not isinstance(numeric_level, int):
        raise ValueError(f"Invalid log level: {log_level_str}")
    logging.basicConfig(level=numeric_level,
                        format='%(asctime)s - %(levelname)s - %(name)s - %(message)s',
                        handlers=[logging.StreamHandler(sys.stdout)])

# --- ARN Parsing ---
ARN_REGEX = re.compile(r"arn:aws:ssm:(?P<region>[^:]+):(?P<account_id>[^:]+):document/(?P<name>.*)")

def parse_arn(arn_string):
    """Parses an SSM Document ARN and returns region and name."""
    match = ARN_REGEX.match(arn_string)
    if match:
        return match.group("region"), match.group("name")
    return None, None

# --- Core Logic ---
def get_document_content(ssm_client, document_name):
    """Fetches and parses the content of an SSM document."""
    try:
        response = ssm_client.get_document(Name=document_name, DocumentFormat='JSON')
        content_str = response.get('Content')
        if not content_str:
            logger.warning(f"Document '{document_name}' has no content.")
            return None
        return json.loads(content_str)
    except ClientError as e:
        if e.response.get('Error', {}).get('Code') == 'InvalidDocument':
             logger.warning(f"Document '{document_name}' not found or invalid format (as per AWS).")
        else:
            logger.error(f"AWS ClientError fetching document '{document_name}': {e}")
        return None
    except json.JSONDecodeError:
        logger.error(f"Failed to parse JSON content for document '{document_name}'. Content may not be valid JSON.")
        return None
    except Exception as e: # Catch any other unexpected errors during fetch/parse
        logger.error(f"Unexpected error fetching/parsing document '{document_name}': {e}")
        return None

def has_outdated_python_runtime(document_content, old_runtimes_list):
    """Checks if the document content uses any of the specified old Python runtimes."""
    if not document_content or not isinstance(document_content, dict):
        return False

    for step in document_content.get("mainSteps", []):
        if isinstance(step, dict) and step.get("action") == "aws:executeScript":
            inputs = step.get("inputs", {})
            if isinstance(inputs, dict):
                runtime = inputs.get("Runtime")
                if runtime in old_runtimes_list:
                    logger.debug(f"Found outdated runtime '{runtime}' in step '{step.get('name', 'UnnamedStep')}'")
                    return True
    return False

def filter_ssm_documents(input_file, output_file, old_runtimes_list):
    """
    Reads SSM document ARNs, fetches their content, filters for outdated Python runtimes,
    and writes matching ARNs to the output file.
    """
    if not BOTO3_AVAILABLE:
        logger.critical("Boto3 library is not installed. This script cannot function without it. Please run 'pip install boto3'.")
        return False

    logger.info(f"Starting SSM document filtering.")
    logger.info(f"Input file: {input_file}")
    logger.info(f"Output file: {output_file}")
    logger.info(f"Outdated runtimes to check: {old_runtimes_list}")

    try:
        with open(input_file, 'r') as f_in:
            arns_to_process = [line.strip() for line in f_in if line.strip()]
    except FileNotFoundError:
        logger.error(f"Input file '{input_file}' not found. Exiting.")
        return False

    if not arns_to_process:
        logger.info("Input file is empty. No documents to process.")
        try:
            with open(output_file, 'w') as f_out: # Create empty output file
                pass
        except IOError as e:
            logger.error(f"Could not write (empty) output file '{output_file}': {e}")
            return False
        return True

    filtered_arns = []
    processed_count = 0
    found_count = 0

    ssm_clients = {} # Cache Boto3 clients per region

    for arn in arns_to_process:
        processed_count += 1
        logger.debug(f"Processing ARN: {arn}")
        region, doc_name = parse_arn(arn)

        if not region or not doc_name:
            logger.warning(f"Could not parse ARN: '{arn}'. Skipping.")
            continue

        try:
            if region not in ssm_clients:
                logger.debug(f"Initializing Boto3 SSM client for region: {region}")
                ssm_clients[region] = boto3.client('ssm', region_name=region)
        except (NoCredentialsError, PartialCredentialsError):
            logger.error("AWS credentials not found or incomplete. Please configure your AWS environment. Aborting.")
            return False
        except ClientError as e:
             logger.error(f"Failed to initialize Boto3 client for region {region} due to ClientError: {e}. Skipping region.")
             continue
        except Exception as e:
            logger.error(f"Unexpected error initializing Boto3 client for region {region}: {e}. Skipping region.")
            continue

        ssm_client = ssm_clients[region]
        document_content = get_document_content(ssm_client, doc_name)

        if document_content:
            if has_outdated_python_runtime(document_content, old_runtimes_list):
                logger.info(f"Found outdated Python runtime in document: {arn}")
                filtered_arns.append(arn)
                found_count += 1

    try:
        with open(output_file, 'w') as f_out:
            for arn_to_write in filtered_arns:
                f_out.write(f"{arn_to_write}\n")
    except IOError as e:
        logger.error(f"Could not write to output file '{output_file}': {e}")
        return False

    logger.info(f"SSM document filtering complete.")
    logger.info(f"Processed {processed_count} documents.")
    logger.info(f"Found {found_count} documents with outdated Python runtimes.")
    logger.info(f"Filtered list saved to '{output_file}'.")
    return True

# --- Main Execution ---
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Filter AWS SSM Automation documents for outdated Python runtimes.")
    parser.add_argument("--input-file", default=DEFAULT_INPUT_FILENAME,
                        help=f"File containing SSM document ARNs, one per line. Default: {DEFAULT_INPUT_FILENAME}")
    parser.add_argument("--output-file", default=DEFAULT_OUTPUT_FILENAME,
                        help=f"File to write filtered ARNs to. Default: {DEFAULT_OUTPUT_FILENAME}")
    parser.add_argument("--old-runtimes", default=",".join(DEFAULT_OLD_RUNTIMES),
                        help=f"Comma-separated list of Python runtimes to consider outdated. Default: {','.join(DEFAULT_OLD_RUNTIMES)}")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
                        help="Set the logging level. Default: INFO")

    args = parser.parse_args()

    setup_logging(args.log_level)

    if not BOTO3_AVAILABLE:
        logger.critical("Boto3 library is not installed. This script cannot function without it. Please run 'pip install boto3'.")
        sys.exit(2)

    old_runtimes = [rt.strip() for rt in args.old_runtimes.split(',') if rt.strip()]

    if not filter_ssm_documents(args.input_file, args.output_file, old_runtimes):
        sys.exit(1)
    sys.exit(0)
