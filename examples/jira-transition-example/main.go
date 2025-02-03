package main
import (
    "context"
    "encoding/json"
    "os"
    "fmt"
    jira "github.com/andygrunwald/go-jira/v2/cloud"
  )
  /*
    JiraTransitionResponse is the json formatted predicate that will be returned to the calling build process for cresting an evidence
    its structure should be:

    {
    "transition": "<transition-name>",
    "allJiraTransitionsFound": "<true/false>",
    "tasks": [
        {
        "jira_id": "<jira-id>",
        "transition_found": "<true/false>"
        }
    ]
   }

   notice that the calling client should first check that return value was 0 before using the response JSON,
   otherwise the response is an error message which cannot be parsed
   */

type TransitionCheckResponse struct {
    Transition string `json:"transition"`
    AllJiraTransitionsFound bool `json:"allJiraTransitionsFound"`
    Tasks []JiraTransitionResult `json:"tasks"`
}

type JiraTransitionResult struct {
	JiraId           string `json:"jira_id"`
	TransitionFound  bool   `json:"transition_found"`
}

func main() {
    // get checked transition name and JIRA IDs from command-line arguments
	if len(os.Args) < 3 {
        fmt.Println("No command-line arguments provided, please send checked transition name and at least one JIRA ID(s)")
        return
    }
    transitionChecked := os.Args[1]
    // Create a new Jira client
    jira_token := os.Getenv("jira_token")
    if jira_token == "" {
        fmt.Println("JIRA token not found, set jira_token variable")
        os.Exit(1)
    }
    jira_url := os.Getenv("jira_url")
    if jira_url == "" {
        fmt.Println("JIRA URL not found, set jira_url variable")
        os.Exit(1)
    }
    jira_username := os.Getenv("jira_username")
    if jira_username == "" {
        fmt.Println("JIRA username not found, set jira_username variable")
        os.Exit(1)
    }
    // connect to JIRA
    tp := jira.BasicAuthTransport{
        Username: jira_username,
		APIToken: jira_token,
	}
    client, err := jira.NewClient(jira_url, tp.Client())
    if err != nil {
		fmt.Printf("\njira.NewClient error: %v\n", err)
		os.Exit(1)
	}
    // initialize the response
    transitionCheckResponse := TransitionCheckResponse{}
    transitionCheckResponse.AllJiraTransitionsFound = true
    transitionCheckResponse.Transition = transitionChecked

    // loop over all JIRAs sent to the fucntion
    for _, jiraId := range os.Args[2:] {
        transitionFound := false

        transitions, _, err := client.Issue.GetTransitions(context.Background(), jiraId)
        if err != nil {
            fmt.Printf("Got error for jira id %d: %v", jiraId, err)
            os.Exit(1)
        } else if transitions != nil {
            //fmt.Printf("Got %d transitions for jira id %d\n",jiraId , len(transitions))
            // checking if the transition is found
            for _, transition := range transitions {
                if transition.Name == transitionChecked {
                    transitionFound = true
                    break
                }
            }
        }
        // adding the jira result to the list of results
        jiraTransitionResult := JiraTransitionResult{
            JiraId: jiraId,
            TransitionFound: transitionFound,
        }
        transitionCheckResponse.Tasks = append(transitionCheckResponse.Tasks, jiraTransitionResult)
        // check if all transitions are found
        if !transitionFound {
            transitionCheckResponse.AllJiraTransitionsFound = false
        }
    }
    // marshal the response to JSON
	jsonBytes, err := json.Marshal(transitionCheckResponse)
	if err != nil {
		fmt.Println("Error marshaling JSON", err)
		os.Exit(1)
	}
	//logger.Println("returning response", response)

	// return response to caller through stdout
	os.Stdout.Write(jsonBytes)
 }
