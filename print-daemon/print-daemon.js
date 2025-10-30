require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { exec } = require("child_process");

const PRINT_QUEUE_PATH = "./print_queue/";
const PRINTED_PATH = "./printed/";
const FAILED_PATH = "./failed/";

const PRINT_DELAY_MS = parseInt(process.env.PRINT_DRIVER_DELAY) || 1000;

const printPDF = (filePath, callback) => {
  const command = `lp -d DYMO_LabelWriter_550 ${filePath}`;
  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Printing error: ${error.message}`);
      return callback(error);
    }
    if (stderr) {
      console.error(`Printer stderr: ${stderr}`);
      return callback(new Error(stderr));
    }
    console.log(`Printed: ${filePath}`);
    callback(null);
  });
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const processPrintQueue = async () => {
  const files = fs.readdirSync(PRINT_QUEUE_PATH).filter((file) => file.endsWith(".pdf"));

  for (const file of files) {
    const fullPath = path.join(PRINT_QUEUE_PATH, file);

    try {
      // Wait before printing to allow printer buffer to clear
      await sleep(PRINT_DELAY_MS);

      await new Promise((resolve, reject) => {
        printPDF(fullPath, (err) => {
          if (err) {
            reject(err);
          } else {
            resolve();
          }
        });
      });

      const printedPath = path.join(PRINTED_PATH, file);
      fs.renameSync(fullPath, printedPath);
    } catch (err) {
      console.error(`Failed to print ${file}:`, err.message);
      const failedPath = path.join(FAILED_PATH, file);
      fs.renameSync(fullPath, failedPath);
    }
  }
};

setInterval(processPrintQueue, 3000);
