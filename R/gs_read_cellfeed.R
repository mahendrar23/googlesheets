#' Read data from cells
#'
#' This function consumes data via the "cell feed", which, as the name suggests,
#' retrieves data cell by cell. Note that the output is a \code{tbl_df} or
#' \code{data.frame} with \strong{one row per cell}.
#'
#' Use the \code{range} argument to specify which cells you want to read. See
#' the examples and the help file for the \link[=cell-specification]{cell
#' specification functions} for various ways to limit consumption to, e.g., a
#' rectangle or certain columns. If \code{range} is specified, the associated
#' cell limits will be checked for internal consistency and compliance with the
#' known extent of the worksheet. If no limits are provided, all cells will be
#' returned but consider that \code{\link{gs_read_csv}} and
#' \code{\link{gs_read_listfeed}} are much faster ways to consume all the data
#' from a rectangular worksheet.
#'
#' Empty cells, even if "embedded" in a rectangular region of populated cells,
#' are not normally returned by the cell feed. This function won't return them
#' either when \code{return_empty = FALSE} (default), but will if you set
#' \code{return_empty = TRUE}. If you don't specify any limits AND you set
#' \code{return_empty = TRUE}, you could be in for a bit of a wait, as the feed
#' will return all cells, which defaults to 1000 rows and 26 columns.
#'
#' @template ss
#' @template ws
#' @template range
#' @param return_empty logical; indicates whether to return empty cells
#' @param return_links logical; indicates whether to return the edit and self
#'   links (used internally in cell editing workflow)
#' @template verbose
#'
#' @seealso \code{\link{gs_reshape_cellfeed}} or
#'   \code{\link{gs_simplify_cellfeed}} to perform reshaping or simplification,
#'   respectively; \code{\link{gs_read}} is a pre-made wrapper that combines
#'   \code{gs_read_cellfeed} and \code{\link{gs_reshape_cellfeed}}
#'
#' @examples
#' \dontrun{
#' gap_ss <- gs_gap() # register the Gapminder example sheet
#' first_4_rows <-
#'   gs_read_cellfeed(gap_ss, "Asia", range = cell_limits(c(NA, 4)))
#' first_4_rows
#' gs_reshape_cellfeed(first_4_rows)
#' gs_reshape_cellfeed(gs_read_cellfeed(gap_ss, "Asia",
#'                       range = cell_limits(c(NA, 4), c(3, NA))))
#' }
#' @family data consumption functions
#'
#' @export
gs_read_cellfeed <- function(
  ss, ws = 1, range = NULL,
  return_empty = FALSE, return_links = FALSE,
  verbose = TRUE) {

  stopifnot(inherits(ss, "googlesheet"))
  this_ws <- gs_ws(ss, ws, verbose)

  limits <- range %>%
    cellranger::as.cell_limits() %>%
    limit_list()
  limits <- limits %>%
    validate_limits(this_ws$row_extent, this_ws$col_extent)

  query <- limits
  if(return_empty) {
    ## the return-empty parameter is not documented in current sheets API, but
    ## is discussed in older internet threads re: the older gdata API; so if
    ## this stops working, consider that they finally stopped supporting this
    ## query parameter
    query <- query %>% c(list("return-empty" = "true"))
  }

  ## to prevent appending of "?=" to url when query elements are all NULL
  if(query %>% unlist() %>% is.null()) {
    query <- NULL
    ## I think this can be eliminated upon next CRAN release of httr
    ## https://github.com/hadley/httr/commit/6d06ad571316dcba5944a5e545c374b64d6979d6
  }

  req <- gsheets_GET(this_ws$cellsfeed, query = query)

  ns <- xml2::xml_ns_rename(xml2::xml_ns(req$content), d1 = "feed")

  x <- req$content %>%
    xml2::xml_find_all("feed:entry", ns)

  if(length(x) == 0L) {
    # the pros outweighed the cons re: setting up a zero row data.frame that,
    # at least, has the correct variables
    x <- dplyr::data_frame(cell = character(),
                           cell_alt = character(),
                           row = integer(),
                           col = integer(),
                           cell_text = character(),
                           edit_link = character(),
                           cell_id = character())
  } else {
    edit_links <- x %>%
      xml2::xml_find_all(".//feed:link[@rel='edit']", ns) %>%
      xml2::xml_attr("href")

    ## this will be true if user does not have permission to edit
    if(length(edit_links) == 0) {
      edit_links <- NA_character_
    }

    x <- dplyr::data_frame_(
      list(cell = ~ xml2::xml_find_all(x, ".//feed:title", ns) %>%
             xml2::xml_text(),
           edit_link = ~ edit_links,
           cell_id = ~ xml2::xml_find_all(x, ".//feed:id", ns) %>%
             xml2::xml_text(),
           cell_alt = ~ cell_id %>% basename(),
           row = ~ xml2::xml_find_all(x, ".//gs:cell", ns) %>%
             xml2::xml_attr("row") %>%
             as.integer(),
           col = ~ xml2::xml_find_all(x, ".//gs:cell", ns) %>%
             xml2::xml_attr("col") %>%
             as.integer(),
           cell_text = ~ xml2::xml_find_all(x, ".//gs:cell", ns) %>%
             xml2::xml_text()
      ))
    # see issue #19 about all the places cell data is (mostly redundantly)
    # stored in the XML, such as: content_text = x$content$text,
    # cell_inputValue = x$cell$.attrs["inputValue"], cell_numericValue =
    # x$cell$.attrs["numericValue"], when/if we think about formulas
    # explicitly, we will want to come back and distinguish between inputValue
    # and numericValue
  }

  x <- x %>%
    dplyr::select_(~ cell, ~ cell_alt, ~ row, ~ col, ~ cell_text,
                   ~ edit_link, ~ cell_id) %>%
    dplyr::as_data_frame()

  attr(x, "ws_title") <- this_ws$ws_title

  if(return_links) {
    x
  } else {
    x %>%
      dplyr::select_(~ -edit_link, ~ -cell_id)
  }

}

validate_limits <- function(
  limits, ws_row_extent = NULL, ws_col_extent = NULL) {

  if(is.null(limits)) return(NULL)

  ## min and max must be <= nominal worksheet extent
  jfun <- function(x, upper_bound) {
    x_name <- deparse(substitute(x))
    ub_name <- deparse(substitute(upper_bound))
    if(!is.null(x) && !is.null(upper_bound) && x > upper_bound) {
      mess <-
        sprintf("%s must be less than or equal to %s\n%s = %d, %s = %d\n",
                x_name, ub_name, x_name, x, ub_name, upper_bound)
      stop(mess)
    }
  }
  jfun(limits[["min-row"]], ws_row_extent)
  jfun(limits[["max-row"]], ws_row_extent)
  jfun(limits[["min-col"]], ws_col_extent)
  jfun(limits[["max-col"]], ws_col_extent)

  limits

}
